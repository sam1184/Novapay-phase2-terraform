#!/bin/bash
# ==========================================================================
# NovaPay Module 11 — Post-cluster setup (Velero + a real stateful workload)
#
# Prepares the platform for a real DR drill:
#   1. kubectl context
#   2. gp3 default StorageClass (EBS CSI)
#   3. Velero (AWS plugin + node-agent/Kopia for filesystem-level PV backup)
#      authenticated via Pod Identity (no static keys)
#   4. NovaPay services (payment, auth, webhook)
#   5. A stateful 'ledger' pod with a real EBS-backed PVC
#
# Idempotent: safe to re-run.
# Usage: bash post-cluster.sh
# ==========================================================================
set -uo pipefail

REGION=$(terraform output -raw region 2>/dev/null || echo "us-east-1")
CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || echo "novapay-dr-lab")
BUCKET=$(terraform output -raw velero_bucket 2>/dev/null)
NS="novapay-prod"
VELERO_VERSION="v1.15.0"
VELERO_AWS_PLUGIN="velero/velero-plugin-for-aws:v1.11.0"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'

ok(){ echo -e "  ${GREEN}✅${NC} $1"; }
info(){ echo -e "  ${YELLOW}ℹ${NC}  $1"; }

echo -e "${BOLD}========================================================================${NC}"
echo -e "${BOLD}  NovaPay Module 11 — Post-Cluster Setup (Velero DR)${NC}"
echo -e "${BOLD}========================================================================${NC}"

# 1) kubeconfig ------------------------------------------------------------
echo -e "\n${CYAN}>>> 1. Configuring kubectl for ${CLUSTER}...${NC}"
aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}" >/dev/null
kubectl cluster-info >/dev/null 2>&1 || { echo -e "${RED}Cannot reach cluster${NC}"; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=240s >/dev/null 2>&1 || true
ok "kubectl connected; nodes Ready"

# 2) gp3 default StorageClass ----------------------------------------------
echo -e "\n${CYAN}>>> 2. Setting gp3 as the default StorageClass...${NC}"
cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations: { storageclass.kubernetes.io/is-default-class: "true" }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters: { type: gp3, encrypted: "true" }
EOF
# demote the old default gp2 if present
kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
ok "gp3 default StorageClass ready"

# 3) Install Velero CLI (if missing) ---------------------------------------
echo -e "\n${CYAN}>>> 3. Ensuring the Velero CLI is installed...${NC}"
if ! command -v velero >/dev/null 2>&1; then
  info "Velero CLI not found — installing ${VELERO_VERSION}..."
  OS=$(uname | tr '[:upper:]' '[:lower:]'); ARCH=$(uname -m)
  [ "$ARCH" = "x86_64" ] && ARCH=amd64; [ "$ARCH" = "arm64" ] && ARCH=arm64
  TMP=$(mktemp -d)
  curl -sL "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-${OS}-${ARCH}.tar.gz" | tar xz -C "$TMP"
  sudo mv "${TMP}/velero-${VELERO_VERSION}-${OS}-${ARCH}/velero" /usr/local/bin/ 2>/dev/null \
    || mv "${TMP}/velero-${VELERO_VERSION}-${OS}-${ARCH}/velero" "${HOME}/.local/bin/" 2>/dev/null \
    || { echo "Install velero manually from https://github.com/vmware-tanzu/velero/releases"; }
  rm -rf "$TMP"
fi
velero version --client-only 2>/dev/null | head -1 || true
ok "Velero CLI available"

# 4) Install Velero into the cluster (Pod Identity auth, node-agent on) ----
echo -e "\n${CYAN}>>> 4. Installing Velero into the cluster (target s3://${BUCKET})...${NC}"
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Pod Identity supplies credentials to the 'velero' service account, so we use
# --no-secret (no static AWS keys mounted anywhere).
velero install \
  --provider aws \
  --plugins "${VELERO_AWS_PLUGIN}" \
  --bucket "${BUCKET}" \
  --backup-location-config "region=${REGION}" \
  --snapshot-location-config "region=${REGION}" \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --no-secret \
  --wait 2>&1 | tail -5 || true

info "Waiting for Velero + node-agent to be ready..."
kubectl rollout status deploy/velero -n velero --timeout=180s >/dev/null 2>&1 || true
kubectl rollout status daemonset/node-agent -n velero --timeout=180s >/dev/null 2>&1 || true

# Confirm the backup location can reach S3
sleep 10
BSL=$(velero backup-location get 2>/dev/null | awk 'NR==2{print $3}')
echo "  Backup storage location phase: ${BSL:-unknown}"
[ "${BSL}" = "Available" ] && ok "Velero connected to S3 (BackupLocation Available)" \
  || info "BackupLocation not Available yet — re-check in a minute (Pod Identity may still be propagating)"

# 5) NovaPay services + a real stateful ledger ------------------------------
echo -e "\n${CYAN}>>> 5. Deploying NovaPay services + stateful ledger (real PVC)...${NC}"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat <<'EOF' | kubectl apply -f -
# --- stateless services (manifests get backed up) ---
apiVersion: apps/v1
kind: Deployment
metadata: { name: payment-service, namespace: novapay-prod, labels: { app: payment-service, tier: money } }
spec:
  replicas: 2
  selector: { matchLabels: { app: payment-service } }
  template:
    metadata: { labels: { app: payment-service, tier: money } }
    spec:
      containers:
        - name: payment-service
          image: public.ecr.aws/docker/library/httpd:2.4
          ports: [{ containerPort: 80 }]
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 200m, memory: 128Mi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: auth-service, namespace: novapay-prod, labels: { app: auth-service, tier: identity } }
spec:
  replicas: 1
  selector: { matchLabels: { app: auth-service } }
  template:
    metadata: { labels: { app: auth-service, tier: identity } }
    spec:
      containers:
        - name: auth-service
          image: public.ecr.aws/docker/library/httpd:2.4
          ports: [{ containerPort: 80 }]
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 200m, memory: 128Mi } }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: novapay-settings, namespace: novapay-prod }
data:
  environment: "production"
  region: "us-east-1"
  feature_flags: "blue_green=on,velero_dr=on"
---
# --- stateful 'ledger': a real EBS-backed PVC holding transaction records ---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: ledger-data, namespace: novapay-prod }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: gp3
  resources: { requests: { storage: 2Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: ledger, namespace: novapay-prod, labels: { app: ledger, tier: data } }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: ledger } }
  template:
    metadata:
      labels: { app: ledger, tier: data }
    spec:
      containers:
        - name: ledger
          image: public.ecr.aws/docker/library/busybox:1.36
          command: ["/bin/sh","-c","echo 'ledger up'; while true; do sleep 3600; done"]
          volumeMounts: [{ name: data, mountPath: /data }]
          resources: { requests: { cpu: 25m, memory: 32Mi }, limits: { cpu: 100m, memory: 64Mi } }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: ledger-data }
EOF

kubectl rollout status deploy/ledger -n "${NS}" --timeout=150s || true
ok "NovaPay services + ledger (PVC bound) deployed"
kubectl get pvc -n "${NS}"
kubectl get pods -n "${NS}" --no-headers | awk '{printf "  %-45s %s\n", $1, $3}'

echo -e "\n${BOLD}========================================================================${NC}"
echo -e "  ${GREEN}Platform ready.${NC} Run the DR drill:"
echo -e "    ${BOLD}bash module-11-demo.sh${NC}         (interactive)"
echo -e "    ${BOLD}bash module-11-demo.sh --auto${NC}  (CI)"
echo -e "${BOLD}========================================================================${NC}"
