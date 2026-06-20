# =============================================================================
# NovaPay Module 10 — AWS DevOps Agent Lab :: Base Infrastructure
#
# This Terraform builds the PLATFORM that AWS DevOps Agent operates on, plus the
# AWS-side prerequisites the agent needs to investigate incidents end-to-end:
#
#   PLATFORM
#     - VPC (2 public + 2 private subnets, NAT)
#     - EKS cluster (control-plane audit logging ON  -> CloudWatch)
#     - VPC CNI / kube-proxy / CoreDNS / Pod Identity add-ons
#     - Amazon CloudWatch Observability add-on (Container Insights: metrics + logs)
#     - One managed node group (t3.medium x 2)
#     - ECR repos for payment-service & webhook-service
#
#   DEVOPS AGENT PREREQUISITES
#     - IAM role for the DevOps Agent "Agent Space" (read/describe introspection)
#     - CloudWatch metric alarm on payment-service 5xx rate (investigation trigger)
#     - SNS topic + EventBridge rule (alarm state-change -> agent trigger hook)
#     - IAM (Pod Identity) for ArgoCD image updater & the LB controller
#
# AWS DevOps Agent itself is a managed service configured in the console / via its
# API + OAuth handshakes (GitHub/Slack). Terraform creates the deterministic
# pieces; post-cluster.sh + module-10-demo.sh exercise the agent end-to-end.
#
# Usage:
#   cd devops-agent-lab
#   terraform init
#   terraform apply                  (~14 min)
#   bash post-cluster.sh             (~6 min  : ArgoCD + NovaPay services + observability)
#   bash module-10-demo.sh           (the interactive capability-validation lab)
#   bash teardown.sh
#
# Cost: ~$0.40/hour while running. ALWAYS run teardown.sh when done.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region" { default = "us-east-1" } # DevOps Agent home Region
variable "cluster_name" { default = "novapay-devops-agent-lab" }
variable "vpc_cidr" { default = "10.120.0.0/16" }
variable "alarm_email" {
  description = "Optional email for SNS incident notifications. Empty = skip."
  default     = ""
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# — VPC ——————————————————————————————————————————————————————————————

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
    Name                     = "${var.cluster_name}-public-${count.index}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]
  tags = {
    Name                              = "${var.cluster_name}-private-${count.index}"
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

# — EKS Cluster (audit logging ON so the agent can read who-did-what) ———————

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

  # Control-plane logs to CloudWatch. 'audit' is what lets DevOps Agent answer
  # "who deleted this ConfigMap" — a core EKS-native diagnosis capability.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# — Node group ——————————————————————————————————————————————————————————

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

# Allows the node / CloudWatch Observability add-on to ship Container Insights
# metrics + logs to CloudWatch — the agent's primary native signal source.
resource "aws_iam_role_policy_attachment" "node_cw" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "lab-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = ["t3.medium"]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_role_policy_attachment.node_cw,
  ]
}

# — Add-ons ——————————————————————————————————————————————————————————

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
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

# Container Insights (metrics + container logs -> CloudWatch). This is the
# native observability stream AWS DevOps Agent correlates during an investigation.
resource "aws_iam_role" "cw_observability" {
  name = "${var.cluster_name}-cw-observability"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cw_observability" {
  role       = aws_iam_role.cw_observability.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_pod_identity_association" "cw_observability" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"
  role_arn        = aws_iam_role.cw_observability.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

resource "aws_eks_addon" "cw_observability" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_pod_identity_association.cw_observability]
}

# — ECR repos for the two NovaPay services this lab focuses on ———————————————

resource "aws_ecr_repository" "payment" {
  name                 = "novapay-lab/payment-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "webhook" {
  name                 = "novapay-lab/webhook-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

# — payment-service Pod Identity: publish its OWN real measured metrics ——————
# The payment-service metrics sidecar counts ACTUAL request outcomes from the
# app's access log and publishes them with cloudwatch:PutMetricData. No synthetic
# values — the numbers are the real count of requests/5xx the app handled.
# Scoped so it can ONLY write to the NovaPay/payment-service namespace.

resource "aws_iam_role" "payment_sa" {
  name = "${var.cluster_name}-payment-sa"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "payment_sa_putmetric" {
  name = "put-metric-data"
  role = aws_iam_role.payment_sa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "cloudwatch:PutMetricData"
      Resource = "*"
      Condition = {
        StringEquals = { "cloudwatch:namespace" = "NovaPay/payment-service" }
      }
    }]
  })
}

resource "aws_eks_pod_identity_association" "payment_sa" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "novapay-prod"
  service_account = "payment-sa"
  role_arn        = aws_iam_role.payment_sa.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# — AWS Load Balancer Controller (Pod Identity) — front door for the services —

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

# — DEVOPS AGENT PREREQ 1: IAM role for the Agent Space (read-only) ——————————
# The DevOps Agent assumes this role to introspect your account. Least-privilege:
# describe/get/list only. The agent recommends; it does not mutate via this role.

data "aws_iam_policy_document" "agent_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "devops_agent_space" {
  name                = "${var.cluster_name}-devops-agent-space"
  assume_role_policy  = data.aws_iam_policy_document.agent_trust.json
  description         = "Read/describe introspection role for the NovaPay DevOps Agent Space"
}

data "aws_iam_policy_document" "agent_readonly" {
  statement {
    sid    = "ObservabilityRead"
    effect = "Allow"
    actions = [
      "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*",
      "logs:Describe*", "logs:Get*", "logs:FilterLogEvents",
      "logs:StartQuery", "logs:GetQueryResults", "logs:StopQuery",
      "xray:Get*", "xray:BatchGet*"
    ]
    resources = ["*"]
  }
  statement {
    sid    = "PlatformRead"
    effect = "Allow"
    actions = [
      "eks:Describe*", "eks:List*", "ec2:Describe*",
      "elasticloadbalancing:Describe*", "ecr:Describe*", "ecr:List*",
      "cloudtrail:LookupEvents", "tag:GetResources",
      "autoscaling:Describe*", "sns:GetTopicAttributes", "sns:ListSubscriptionsByTopic"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent_readonly" {
  name   = "readonly-introspection"
  role   = aws_iam_role.devops_agent_space.id
  policy = data.aws_iam_policy_document.agent_readonly.json
}

# — DEVOPS AGENT PREREQ 2: incident SNS + alarm + EventBridge trigger ————————

resource "aws_sns_topic" "incidents" {
  name = "${var.cluster_name}-incidents"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.incidents.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# The investigation trigger: a metric-math alarm on payment-service 5xx rate.
# module-10-demo.sh publishes custom metrics in NovaPay/payment-service to fire it.
resource "aws_cloudwatch_metric_alarm" "payment_errorrate" {
  alarm_name          = "novapay-payment-errorrate"
  alarm_description   = "payment-service 5xx error rate exceeded 5% (DevOps Agent investigation trigger)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "errpct"
    expression  = "100*(errors/requests)"
    label       = "5xx error rate %"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      metric_name = "Http5xxCount"
      namespace   = "NovaPay/payment-service"
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id = "requests"
    metric {
      metric_name = "HttpRequestCount"
      namespace   = "NovaPay/payment-service"
      period      = 60
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.incidents.arn]
  ok_actions    = [aws_sns_topic.incidents.arn]
}

# How an alarm auto-starts an investigation: EventBridge captures the ALARM
# state change. In the console you add the Agent Space as a target; here we wire
# SNS so the hook is verifiable end-to-end.
resource "aws_cloudwatch_event_rule" "alarm_to_agent" {
  name        = "${var.cluster_name}-alarm-to-devops-agent"
  description = "Route payment-service alarm ALARM state to the DevOps Agent trigger"
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.payment_errorrate.alarm_name]
      state     = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "alarm_to_sns" {
  rule      = aws_cloudwatch_event_rule.alarm_to_agent.name
  target_id = "incidents-sns"
  arn       = aws_sns_topic.incidents.arn
}

resource "aws_sns_topic_policy" "allow_events" {
  arn = aws_sns_topic.incidents.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.incidents.arn
    }]
  })
}

# — Outputs ——————————————————————————————————————————————————————————

output "cluster_name" { value = aws_eks_cluster.main.name }
output "region" { value = var.region }
output "vpc_id" { value = aws_vpc.main.id }
output "account_id" { value = data.aws_caller_identity.current.account_id }
output "payment_ecr_url" { value = aws_ecr_repository.payment.repository_url }
output "webhook_ecr_url" { value = aws_ecr_repository.webhook.repository_url }
output "alarm_name" { value = aws_cloudwatch_metric_alarm.payment_errorrate.alarm_name }
output "metric_namespace" { value = "NovaPay/payment-service" }
output "incidents_sns_topic_arn" { value = aws_sns_topic.incidents.arn }
output "devops_agent_space_role_arn" {
  value       = aws_iam_role.devops_agent_space.arn
  description = "Paste this when creating the Agent Space in the DevOps Agent console"
}
output "lb_controller_role_arn" { value = aws_iam_role.lb_controller.arn }
output "next_step" { value = "Run: bash post-cluster.sh" }
