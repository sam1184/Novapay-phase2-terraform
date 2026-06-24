# ==============================================================================
# NovaPay Module 12 - Self-hosted LLM Chatbot on EKS (vLLM + AWS Neuron)
#
# Based on the EKS Workshop "Large Language Models with vLLM" module, reframed
# as NovaPay's customer-support assistant. The point for a bank: the model runs
# INSIDE your VPC, so customer prompts (which may mention account/payment detail)
# never leave to a third-party LLM API.
#
# Builds:
#   - VPC (2 public + 2 private subnets, NAT)
#   - EKS cluster + a small system node group (t3.small x 2)
#   - A Neuron accelerator node group (inf2.xlarge, AL2023 Neuron AMI),
#     tainted so only the model pod lands on the expensive accelerator
#   - Add-ons: VPC CNI, kube-proxy, CoreDNS, Pod Identity
#   - AWS Load Balancer Controller IAM (Pod Identity)
#
# post-cluster.sh then installs the Neuron device plugin, deploys Mistral-7B on
# vLLM (OpenAI-compatible API), and a chat UI pointed at it.
#
# Usage:
#   cd chatbot-llm-lab
#   terraform init
#   terraform apply                (~16 min)
#   bash post-cluster.sh           (~15 min : Neuron plugin + vLLM + model download + UI)
#   bash module-12-demo.sh         (the chatbot drill)
#   bash teardown.sh
#
# COST WARNING: inf2.xlarge is ~$0.76/hour on-demand. This is the priciest lab.
# ALWAYS run teardown.sh as soon as you're done.
# ==============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region"               { default = "us-east-1" }
variable "cluster_name"         { default = "novapay-chatbot-lab" }
variable "vpc_cidr"             { default = "10.140.0.0/16" }
# inf2.xlarge = 1 Inferentia2 chip / 2 Neuron cores (matches tensor-parallel-size 2).
# trn1.2xlarge also works if inf2 capacity is unavailable in your AZ.
variable "neuron_instance_type" { default = "inf2.xlarge" }

data "aws_caller_identity"    "current"   {}
data "aws_availability_zones" "available" { state = "available" }

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# — VPC -----------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                   = "${var.cluster_name}-public-${count.index}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]
  tags = {
    Name                            = "${var.cluster_name}-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.cluster_name}-nat" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.cluster_name}-private-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# — EKS cluster ---------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.30"

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# — Node IAM role (shared by both node groups) --------------------------------

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# — System node group (runs CoreDNS, the device plugin, the UI, etc.) ---------

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = ["t3.small"]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# — Neuron accelerator node group (runs ONLY the model) -----------------------
# AL2023_x86_64_NEURON ships the Neuron drivers. The taint keeps everything off
# this expensive node except the vLLM pod, which tolerates it.

resource "aws_eks_node_group" "neuron" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "neuron"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.neuron_instance_type]
  ami_type        = "AL2023_x86_64_NEURON"
  capacity_type   = "ON_DEMAND"
  disk_size       = 200 # the vLLM image (~10GB) + model weights need room

  scaling_config {
    desired_size = 1
    min_size     = 0
    max_size     = 1
  }

  labels = { "neuron.amazonaws.com/neuron-device" = "true" }

  taint {
    key    = "aws.amazon.com/neuron"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# — Add-ons -------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on               = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "eks-pod-identity-agent"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on               = [aws_eks_node_group.system]
}

# — AWS Load Balancer Controller (Pod Identity) -------------------------------

resource "aws_iam_role" "lb_controller" {
  name = "${var.cluster_name}-lb-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_policy" "lb_controller" {
  name = "${var.cluster_name}-lb-controller-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:Describe*", "ec2:Get*", "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress", "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup", "ec2:CreateTags", "ec2:DeleteTags",
        "elasticloadbalancing:*", "iam:CreateServiceLinkedRole",
        "acm:ListCertificates", "acm:DescribeCertificate",
        "wafv2:GetWebACL", "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL",
        "shield:GetSubscriptionState", "tag:GetResources", "tag:TagResources"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# — Outputs -------------------------------------------------------------------

output "cluster_name"          { value = aws_eks_cluster.main.name }
output "region"                { value = var.region }
output "neuron_instance_type"  { value = var.neuron_instance_type }
output "next_step"             { value = "Run: bash post-cluster.sh" }
