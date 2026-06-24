# ==========================================================================
# NovaPay Module 11 — Disaster Recovery with Velero :: Base Infrastructure
#
# Builds the platform for a real DR drill:
#   - VPC (2 public + 2 private subnets, NAT)
#   - EKS cluster + 1 managed node group (t3.small x 2)
#   - Add-ons: VPC CNI, kube-proxy, CoreDNS, Pod Identity, EBS CSI driver
#     (EBS CSI is required so the stateful 'ledger' workload gets a real volume)
#   - An S3 bucket as the Velero backup target (versioned + encrypted)
#   - IAM (Pod Identity) for Velero: S3 access + EBS snapshot permissions
#   - IAM (Pod Identity) for the EBS CSI controller
#
# The DR drill (module-11-demo.sh) writes REAL data into a PVC, backs the whole
# namespace up to S3, deletes the namespace (real disaster), restores it, and
# verifies the real data came back. No synthetic data anywhere.
#
# Usage:
#   cd dr-velero-lab
#   terraform init
#   terraform apply                (~14 min)
#   bash post-cluster.sh           (~5 min : Velero + NovaPay + stateful ledger)
#   bash module-11-demo.sh         (the DR drill)
#   bash teardown.sh
#
# Cost: ~$0.35/hour while running. ALWAYS run teardown.sh when done.
# ==========================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region"       { default = "us-east-1" }
variable "cluster_name" { default = "novapay-dr-lab" }
variable "vpc_cidr"     { default = "10.130.0.0/16" }

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

locals {
  azs    = slice(data.aws_availability_zones.available.names, 0, 2)
  bucket = "novapay-dr-velero-${data.aws_caller_identity.current.account_id}"
}

# — VPC ————————————————————————————————————————————————————————

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
  tags                    = { Name = "${var.cluster_name}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.cluster_name}-private-${count.index}" }
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

# — EKS cluster ————————————————————————————————————————————————

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
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

# — Node group ————————————————————————————————————————————————

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
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

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "lab-nodes"
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

# — Add-ons ————————————————————————————————————————————————————

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.workers]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.workers]
}

# — EBS CSI driver — required so the stateful 'ledger' PVC gets a real volume —

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_pod_identity_association.ebs_csi, aws_eks_node_group.workers]
}

# — S3 backup target for Velero ——————————————————————————————————

resource "aws_s3_bucket" "velero" {
  bucket        = local.bucket
  force_destroy = true # lets teardown.sh delete the bucket even with backups in it
  tags          = { Name = "${var.cluster_name}-velero-backups" }
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# — Velero IAM (Pod Identity) — S3 backups + EBS volume snapshots ————————

resource "aws_iam_role" "velero" {
  name = "${var.cluster_name}-velero"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "velero" {
  name = "velero-backup"
  role = aws_iam_role.velero.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ObjectAccess"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"]
        Resource = ["${aws_s3_bucket.velero.arn}/*"]
      },
      {
        Sid      = "S3BucketAccess"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.velero.arn]
      },
      {
        Sid    = "EBSSnapshots"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes", "ec2:DescribeSnapshots",
          "ec2:CreateTags", "ec2:CreateVolume",
          "ec2:CreateSnapshot", "ec2:DeleteSnapshot"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "velero" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "velero"
  service_account = "velero"
  role_arn        = aws_iam_role.velero.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# — Outputs ————————————————————————————————————————————————————

output "cluster_name"   { value = aws_eks_cluster.main.name }
output "region"         { value = var.region }
output "account_id"     { value = data.aws_caller_identity.current.account_id }
output "velero_bucket"  { value = aws_s3_bucket.velero.id }
output "velero_role_arn" { value = aws_iam_role.velero.arn }
output "next_step"      { value = "Run: bash post-cluster.sh" }
