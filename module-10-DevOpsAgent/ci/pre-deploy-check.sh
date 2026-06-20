#!/usr/bin/env bash
# pre-deploy-check.sh
# ArgoCD PreSync hook / manual pre-deployment gate.
# Blocks a payment-service or auth-service deployment if the two services
# would have incompatible token format expectations after the deploy.
#
# How it works:
#   1. Reads DEPLOY_SERVICE and NEW_TOKEN_FORMAT from env (set by CI or the
#      ArgoCD PreSync Job below).
#   2. Reads the CURRENT live format of the OTHER service from the cluster.
#   3. Fails if the combination would produce a 502 storm.
#
# Usage (manual / CI):
#   DEPLOY_SERVICE=payment-service NEW_TOKEN_FORMAT=v2 ./ci/pre-deploy-check.sh
#   DEPLOY_SERVICE=auth-service    NEW_TOKEN_FORMAT=v2 ./ci/pre-deploy-check.sh
#
# As ArgoCD PreSync hook: the k8s/argocd-presync-job.yaml wraps this script.

set -euo pipefail

NS="${NAMESPACE:-novapay-prod}"
DEPLOY_SERVICE="${DEPLOY_SERVICE:-}"
NEW_FORMAT="${NEW_TOKEN_FORMAT:-}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass(){ echo -e "${GREEN}PASS${NC} $*"; }
fail(){ echo -e "${RED}BLOCK${NC} $*"; exit 1; }
warn(){ echo -e "${YELLOW}WARN${NC} $*"; }

echo "=== NovaPay Pre-Deployment Version Compatibility Check ==="
echo "  Deploying : ${DEPLOY_SERVICE:-<not set>}"
echo "  New format: ${NEW_FORMAT:-<not set>}"
echo ""

if [[ -z "${DEPLOY_SERVICE}" || -z "${NEW_FORMAT}" ]]; then
  echo "  DEPLOY_SERVICE and NEW_TOKEN_FORMAT not set — skipping compatibility gate (pass-through)"
  exit 0
fi

# ── Fetch current live format of the peer service ────────────────────────────
case "${DEPLOY_SERVICE}" in
  payment-service)
    # Changing payment-service: check what auth currently issues
    PEER_FORMAT=$(kubectl get deploy auth-service -n "${NS}" \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AUTH_TOKEN_FORMAT")].value}' \
      2>/dev/null || echo "v1")
    echo "  auth-service currently issues: ${PEER_FORMAT}"
    echo "  payment-service will expect  : ${NEW_FORMAT}"

    if [[ "${PEER_FORMAT}" != "${NEW_FORMAT}" ]]; then
      fail "Deployment blocked: payment-service will expect '${NEW_FORMAT}' tokens but auth-service still issues '${PEER_FORMAT}'. Deploy auth-service with ${NEW_FORMAT} support first, then redeploy payment-service."
    fi
    pass "auth-service already issues ${PEER_FORMAT} — safe to deploy payment-service expecting ${NEW_FORMAT}"
    ;;

  auth-service)
    # Changing auth-service: check what payment currently expects
    PEER_FORMAT=$(kubectl get deploy payment-service -n "${NS}" \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="TOKEN_FORMAT")].value}' \
      2>/dev/null || echo "v1")
    echo "  payment-service currently expects: ${PEER_FORMAT}"
    echo "  auth-service will issue          : ${NEW_FORMAT}"

    if [[ "${PEER_FORMAT}" != "${NEW_FORMAT}" ]]; then
      # Auth switching from v1→v2 while payment still expects v1: hard block
      # Auth switching from v2→v1 while payment expects v2: also hard block
      fail "Deployment blocked: auth-service will issue '${NEW_FORMAT}' tokens but payment-service expects '${PEER_FORMAT}'. Update payment-service to accept '${NEW_FORMAT}' first (or deploy both simultaneously)."
    fi
    pass "payment-service expects ${PEER_FORMAT} — safe to deploy auth-service issuing ${NEW_FORMAT}"
    ;;

  *)
    warn "Unknown service '${DEPLOY_SERVICE}' — no compatibility check defined, allowing deploy"
    ;;
esac

echo ""
echo "=== Pre-deployment check PASSED ==="
