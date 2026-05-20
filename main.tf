terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# ==============================================================================
# MODULE 1: KMS Key for etcd encryption
# ==============================================================================

resource "aws_kms_key" "eks_secrets" {
  description             = "NovaPay EKS etcd secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags = {
    Project     = var.project
    Environment = "production"
  }
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# ==============================================================================
# MODULE 1: EKS Cluster IAM Role
# ==============================================================================

resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Project = var.project }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_controller" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# ==============================================================================
# MODULE 1: Subnet Tags for Karpenter Discovery
# (Tags are now applied directly in vpc.tf subnet resource)
# ==============================================================================

# ==============================================================================
# MODULE 1: EKS Cluster
# ==============================================================================

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
  }

  enabled_cluster_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler"
  ]

  tags = {
    Project     = var.project
    Environment = "production"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_controller,
  ]
}

# ==============================================================================
# MODULE 1: EKS Add-ons (no EBS CSI - not used)
# ==============================================================================

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
  depends_on   = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
  depends_on   = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
  depends_on   = [aws_eks_node_group.system]
}

# ==============================================================================
# MODULE 1: System Node Group IAM Role
# ==============================================================================

resource "aws_iam_role" "system_nodes" {
  name = "${var.cluster_name}-system-nodegroup-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Project = var.project }
}

resource "aws_iam_role_policy_attachment" "system_worker" {
  role       = aws_iam_role.system_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "system_cni" {
  role       = aws_iam_role.system_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "system_ecr" {
  role       = aws_iam_role.system_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "system_ssm" {
  role       = aws_iam_role.system_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ==============================================================================
# MODULE 1: System Node Group
# ==============================================================================

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.system_nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  labels = {
    role = "system"
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = {
    Project     = var.project
    Environment = "production"
    Purpose     = "system-components"
  }

  depends_on = [
    aws_iam_role_policy_attachment.system_worker,
    aws_iam_role_policy_attachment.system_cni,
    aws_iam_role_policy_attachment.system_ecr,
    aws_iam_role_policy_attachment.system_ssm,
  ]
}

# ==============================================================================
# MODULE 2: Spot Service-Linked Role
# Required for any Spot instance launch. Safe to attempt even if it already
# exists in the account — lifecycle ignore_changes prevents drift errors.
# If creation fails with AlreadyExists, run:
#   terraform import aws_iam_service_linked_role.spot arn:aws:iam::ACCOUNT_ID:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot
# ==============================================================================

resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"

  lifecycle {
    ignore_changes = [description]
  }
}
# ==============================================================================

# ==============================================================================
# MODULE 2: Karpenter Node IAM Role
# ==============================================================================

resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeRole-${var.cluster_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Project = var.project }
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ==============================================================================
# MODULE 2: Karpenter Controller IAM Role
# ==============================================================================

resource "aws_iam_role" "karpenter_controller" {
  name = "KarpenterControllerRole-${var.cluster_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = { Project = var.project }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "KarpenterControllerPolicy"
  role   = aws_iam_role.karpenter_controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet", "ec2:CreateLaunchTemplate", "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate", "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages", "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates", "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets", "ec2:DescribeSpotPriceHistory",
          "ec2:RunInstances", "ec2:TerminateInstances"
        ]
        Resource = "*"
      },
      {
        Sid    = "IAM"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile", "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile",
          "iam:PassRole"
        ]
        Resource = "*"
      },
      {
        Sid    = "EKS"
        Effect = "Allow"
        Action = ["eks:DescribeCluster"]
        Resource = aws_eks_cluster.main.arn
      },
      {
        Sid    = "SQS"
        Effect = "Allow"
        Action = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        Sid      = "SSM"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${local.region}::parameter/aws/service/*"
      },
      {
        Sid      = "Pricing"
        Effect   = "Allow"
        Action   = ["pricing:GetProducts"]
        Resource = "*"
      }
    ]
  })
}

# ==============================================================================
# MODULE 2: Pod Identity Association for Karpenter
# ==============================================================================

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn
}

# ==============================================================================
# MODULE 2: SQS Interruption Queue
# ==============================================================================

resource "aws_sqs_queue" "karpenter_interruption" {
  name = var.cluster_name
  tags = { Project = var.project }
}

# ==============================================================================
# MODULE 2: Tag Cluster Security Group for Karpenter Discovery
# ==============================================================================

resource "aws_ec2_tag" "cluster_sg_karpenter" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = "novapay-prod-v2"
}

# ==============================================================================
# MODULE 2: Map Karpenter Node Role into aws-auth (via eksctl in post-apply)
# Note: Access entries require API auth mode. We use eksctl in post-apply.sh instead.
# ==============================================================================

# resource "aws_eks_access_entry" "karpenter_node" {
#   cluster_name  = aws_eks_cluster.main.name
#   principal_arn = aws_iam_role.karpenter_node.arn
#   type          = "EC2_LINUX"
# }
