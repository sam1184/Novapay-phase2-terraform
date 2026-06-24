variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "novapay-prod-eks-v2"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "project" {
  description = "Project name for tagging"
  type        = string
  default     = "NovaPay"
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.0.0"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.100.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (one per AZ)"
  type        = list(string)
  default     = ["10.100.10.0/24", "10.100.20.0/24"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (for NAT gateway)"
  type        = list(string)
  default     = ["10.100.1.0/24", "10.100.2.0/24"]
}
