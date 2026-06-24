#!/bin/bash
# ==========================================================================
# NovaPay Module 11 — Safe Teardown
#
# Removes the workload + Velero (which releases the EBS volume), then destroys
# the infrastructure. The S3 bucket has force_destroy=true so terraform empties
# and deletes it even with backups inside. Safe to run repeatedly.
# ==========================================================================
set -uo pipefail
REGION=$(terraform output -raw region 2>/dev/null || echo "us-east-1")

echo ">>> Deleting Velero schedules + backups (frees S3 + any snapshots)..."
velero schedule delete novapay-hourly --confirm 2>/dev/null || true
velero backup delete --all --confirm 2>/dev/null || true
sleep 5

echo ">>> Deleting the NovaPay namespace (releases the EBS volume)..."
kubectl delete namespace novapay-prod --timeout=180s 2>/dev/null || true

echo ">>> Uninstalling Velero..."
velero uninstall --force 2>/dev/null || kubectl delete namespace velero --timeout=120s 2>/dev/null || true

echo ">>> Waiting for EBS volumes to detach/delete..."
sleep 20

echo ">>> terraform destroy..."
terraform destroy -auto-approve

echo ""
echo "✅ Teardown complete."
echo "   If destroy complained about the S3 bucket, re-run it – force_destroy clears it."
