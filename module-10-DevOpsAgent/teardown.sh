#!/bin/bash
# ===========================================================================
# NovaPay Module 10 — Safe Teardown
#
# Removes in-cluster cloud resources (ALB, controllers) and the Container
# Insights log groups BEFORE terraform destroy, so leftover ENIs / load
# balancers / log groups don't linger or block VPC deletion.
# Safe to run repeatedly. No synthetic data anywhere.
# ===========================================================================

set -uo pipefail

REGION=$(terraform output -raw region 2>/dev/null || echo "us-east-1")
CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || echo "novapay-devops-agent-lab")

echo ">>> Deleting NovaPay workloads + lab artifacts..."
kubectl delete namespace novapay-prod --timeout=120s 2>/dev/null || true

echo ">>> Uninstalling ArgoCD + LB controller..."
kubectl delete namespace argocd --timeout=120s 2>/dev/null || true
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true

echo ">>> Deleting Container Insights log groups for this cluster..."
for LG in "/aws/containerinsights/${CLUSTER}/application" \
           "/aws/containerinsights/${CLUSTER}/dataplane" \
           "/aws/containerinsights/${CLUSTER}/host" \
           "/aws/containerinsights/${CLUSTER}/performance"; do
  aws logs delete-log-group --region "${REGION}" --log-group-name "${LG}" 2>/dev/null || true
done

echo ">>> Waiting for any lab ALBs to deprovision..."
sleep 20

echo ">>> terraform destroy..."
terraform destroy -auto-approve

echo ""
echo "✅ Teardown complete."
echo "   NOTE: delete the DevOps Agent 'Agent Space' in the console separately"
echo "   (it is created in the console, not by Terraform)."
