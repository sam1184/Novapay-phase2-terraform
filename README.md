# NovaPay EKS — Single-Click Deployment (Modules 1–4)

## What This Creates

One `terraform apply` + one `./post-apply.sh` gives you:

- EKS cluster (private, encrypted, logged)
- 2 system nodes (t3.medium, tainted)
- Karpenter v1.0.0 with 2 NodePools (payment-critical + general)
- VPC CNI prefix delegation (110 pods/node)
- All 4 NovaPay services deployed via Helm
- In-cluster PostgreSQL (SSL) + Redis
- Argo Rollouts with payment-service Blue/Green
- ArgoCD dashboard

## Prerequisites

```bash
brew install terraform kubectl helm eksctl awscli
aws sts get-caller-identity  # Must return your account
docker info                  # Docker must be running (for image builds)
```

## Usage

```bash
cd terraform-eks

# 1. Initialize
terraform init

# 2. Deploy everything (takes ~15 minutes)
terraform apply -auto-approve

# 3. Configure kubectl
aws eks update-kubeconfig --name novapay-prod-eks --region us-east-1

# 4. Run post-apply (Helm deploys, Argo Rollouts, ArgoCD)
chmod +x post-apply.sh
./post-apply.sh
```

## Teardown

```bash
./teardown.sh
# Then:
terraform destroy -auto-approve
```

## Architecture

```
terraform apply creates:
├── VPC (10.100.0.0/16) + 2 public + 2 private subnets
├── Internet Gateway + NAT Gateway
├── ECR repositories (auth, charge, webhook, kyc)
├── KMS key (etcd encryption)
├── IAM roles (cluster, system nodes, Karpenter node, Karpenter controller)
├── EKS cluster
├── System node group (2x t3.medium)
├── EKS add-ons (vpc-cni, coredns, kube-proxy, pod-identity-agent)
├── SQS interruption queue
├── Security group tags
└── Pod Identity association

post-apply.sh creates:
├── Builds + pushes Docker images to ECR (v1.0.0 + v2.0.0)
├── Maps Karpenter node role (eksctl)
├── Namespaces + PSA labels
├── Default-deny NetworkPolicy
├── Karpenter (Helm)
├── EC2NodeClass + NodePools
├── Prefix delegation
├── PostgreSQL + Redis (in-cluster)
├── All 4 services (Helm)
├── Argo Rollouts + Blue/Green payment-service
└── ArgoCD
```
