#!/bin/bash
# =============================================================================
# NovaPay - Build v2.0.0 Images (Prerequisite for Module 3+4 Part E)
#
# This script creates v2.0.0 tags for all 4 services by re-tagging the
# existing v1.0.0 images in ECR. Same code, different tag - sufficient for
# demonstrating Blue/Green traffic switching.
#
# Run BEFORE executing Part E (Blue/Green release demo).
# =============================================================================

set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "================================================================"
echo "  NovaPay - Build v2.0.0 Images"
echo "  Account: ${ACCOUNT_ID}"
echo "  Region:  ${REGION}"
echo "================================================================"
echo ""

# Check if v1.0.0 images exist (prerequisite)
echo ">>> Checking v1.0.0 images exist..."
MISSING=false
for svc in auth charge webhook kyc; do
  if ! aws ecr describe-images --repository-name "novapay-poc/${svc}" \
    --image-ids imageTag=v1.0.0 --region ${REGION} >/dev/null 2>&1; then
    echo "  ERROR: novapay-poc/${svc}:v1.0.0 not found in ECR"
    MISSING=true
  else
    echo "  ✅ novapay-poc/${svc}:v1.0.0 exists"
  fi
done

if [ "${MISSING}" = "true" ]; then
  echo ""
  echo "ERROR: v1.0.0 images missing. Run post-apply.sh first to build them."
  exit 1
fi

# Check if v2.0.0 already exists
echo ""
echo ">>> Checking if v2.0.0 images already exist..."
ALL_EXIST=true
for svc in auth charge webhook kyc; do
  if aws ecr describe-images --repository-name "novapay-poc/${svc}" \
    --image-ids imageTag=v2.0.0 --region ${REGION} >/dev/null 2>&1; then
    echo "  ✅ novapay-poc/${svc}:v2.0.0 already exists - skipping"
  else
    echo "  novapay-poc/${svc}:v2.0.0 missing - will create"
    ALL_EXIST=false
  fi
done

if [ "${ALL_EXIST}" = "true" ]; then
  echo ""
  echo "All v2.0.0 images already exist. Nothing to do."
  exit 0
fi

# Create v2.0.0 by re-tagging v1.0.0 manifests in ECR
# This avoids needing Docker locally - uses ECR batch-get-image + put-image
echo ""
echo ">>> Creating v2.0.0 tags from v1.0.0 (ECR manifest copy)..."

for svc in auth charge webhook kyc; do
  REPO="novapay-poc/${svc}"

  if aws ecr describe-images --repository-name "${REPO}" \
    --image-ids imageTag=v2.0.0 --region ${REGION} >/dev/null 2>&1; then
    continue
  fi

  echo "  Tagging ${REPO}:v1.0.0 → v2.0.0..."

  MANIFEST=$(aws ecr batch-get-image \
    --repository-name "${REPO}" \
    --image-ids imageTag=v1.0.0 \
    --query "images[0].imageManifest" \
    --output text \
    --region ${REGION})

  MEDIA_TYPE=$(aws ecr batch-get-image \
    --repository-name "${REPO}" \
    --image-ids imageTag=v1.0.0 \
    --query "images[0].imageManifestMediaType" \
    --output text \
    --region ${REGION})

  aws ecr put-image \
    --repository-name "${REPO}" \
    --image-tag v2.0.0 \
    --image-manifest "${MANIFEST}" \
    --image-manifest-media-type "${MEDIA_TYPE}" \
    --region ${REGION} >/dev/null

  echo "  ✅ ${REPO}:v2.0.0 created"
done

# Verify
echo ""
echo ">>> Verification:"
for repo in novapay-poc/auth novapay-poc/charge novapay-poc/webhook novapay-poc/kyc; do
  TAGS=$(aws ecr list-images --repository-name ${repo} \
    --query "imageIds[*].imageTag" --output text --region ${REGION})
  echo "  ${repo}: ${TAGS}"
done

echo ""
echo "================================================================"
echo "  v2.0.0 images ready. You can now run Part E (Blue/Green demo):"
echo ""
echo "  kubectl argo rollouts set image payment-service \\"
echo "    payment-service=${ECR_BASE}/novapay-poc/charge:v2.0.0 \\"
echo "    -n novapay-prod"
echo "================================================================"
