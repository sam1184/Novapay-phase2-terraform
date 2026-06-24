#!/bin/bash
#
# NovaPay – Teardown Script
# Run BEFORE terraform destroy to clean up Kubernetes resources
#
set -euo pipefail

CLUSTER_NAME="novapay-prod-eks-v2"
REGION="us-east-1"

echo "=================================================="
echo "  NovaPay Teardown"
echo "=================================================="

# Delete Argo Rollout + supporting resources
echo ">>> Deleting Argo Rollout..."
kubectl delete rollout payment-service -n novapay-prod 2>/dev/null || true
kubectl delete svc payment-service-active payment-service-preview -n novapay-prod 2>/dev/null || true
kubectl delete pdb payment-service-pdb -n novapay-prod 2>/dev/null || true
kubectl delete sa payment-service-sa -n novapay-prod 2>/dev/null || true

# Delete Helm releases
echo ">>> Deleting Helm releases..."
helm uninstall auth-service -n novapay-prod 2>/dev/null || true
helm uninstall webhook-service -n novapay-prod 2>/dev/null || true
helm uninstall kyc-service -n novapay-prod 2>/dev/null || true

# Delete database pods
echo ">>> Deleting database pods..."
kubectl delete pod postgres redis -n novapay-prod --force 2>/dev/null || true
kubectl delete svc postgres redis -n novapay-prod 2>/dev/null || true

# Delete controllers
echo ">>> Deleting Argo Rollouts..."
helm uninstall argo-rollouts -n argo-rollouts 2>/dev/null || true

echo ">>> Deleting ArgoCD..."
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  2>/dev/null || true

# Delete Karpenter
echo ">>> Deleting Karpenter NodePools + EC2NodeClass..."
kubectl delete nodepools --all 2>/dev/null || true
kubectl delete ec2nodeclasses --all 2>/dev/null || true

echo ">>> Waiting for Karpenter to terminate workload nodes (90s)..."
sleep 90

echo ">>> Deleting Karpenter Helm release..."
helm uninstall karpenter -n kube-system 2>/dev/null || true

echo ""
echo "  ✅ Kubernetes resources cleaned up"
echo "  Now run: terraform destroy -auto-approve"
echo ""
