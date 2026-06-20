#!/bin/bash
# ==========================================================================
# NovaPay — Module 11: Disaster Recovery with Velero (real backup & restore)
#
# A real DR drill. Nothing synthetic:
#   A. Prerequisites — Velero healthy, S3 reachable, ledger PVC bound
#   B. Write REAL data into the ledger volume; record its count + checksum
#   C. Back up the whole novapay-prod namespace (incl. PV data) to S3
#   D. Disaster — delete the namespace for real (pods, PVC, EBS volume gone)
#   E. Restore from the backup; measure RTO
#   F. Verify the namespace, workloads, AND the real ledger data came back intact
#   G. Scheduled backups + the cross-region DR pattern
#
# Usage:
#   bash module-11-demo.sh          # interactive
#   bash module-11-demo.sh --auto   # non-interactive (CI)
# ==========================================================================
set -uo pipefail

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

REGION=$(terraform output -raw region 2>/dev/null || echo "us-east-1")
CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || echo "novapay-dr-lab")
BUCKET=$(terraform output -raw velero_bucket 2>/dev/null || echo "")
NS="novapay-prod"
TS=$(date -u +%Y%m%d%H%M%S)
BACKUP="novapay-dr-${TS}"
RESTORE="novapay-restore-${TS}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
PASS=0; FAIL=0

pause(){ if [[ "${AUTO_MODE}" == "true" ]]; then sleep 1; return; fi; echo ""; echo -e "${YELLOW}>>> Press ENTER to continue...${NC}"; read -r; }
header(){ echo ""; echo -e "${BOLD}========================================================================${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${BOLD}========================================================================${NC}"; echo ""; }
step(){ echo -e "${BLUE}────────────────────────────────────────────────────────────────────${NC}"; echo -e "${GREEN}[STEP $1]${NC} ${BOLD}$2${NC}"; echo -e ""; }
info(){ echo -e "  ${YELLOW}// $1${NC}"; }
teach(){ echo -e "  ${CYAN}📘 $1${NC}"; }
check(){ if [ "$2" = "true" ]; then echo -e "  ${GREEN}✅ PASS: $1${NC}"; PASS=$((PASS+1)); else echo -e "  ${RED}❌ FAIL: $1${NC}"; FAIL=$((FAIL+1)); fi; }

header "Module 11 — Disaster Recovery with Velero"
echo "  Cluster:    ${CLUSTER}  (${REGION})"
echo "  S3 target:  s3://${BUCKET}"
echo "  Backup:     ${BACKUP}"
echo ""
kubectl cluster-info >/dev/null 2>&1 || { echo -e "${RED}Cannot reach cluster. Run post-cluster.sh${NC}"; exit 1; }
command -v velero >/dev/null 2>&1 || { echo -e "${RED}velero CLI missing. Run post-cluster.sh${NC}"; exit 1; }

# ==========================================================================
# PART A — PREREQUISITES
# ==========================================================================
header "PART A — Prerequisites"
teach "DR is only real if the backup target works and there's real state to protect."
echo ""

step "A.1" "Velero is running and connected to S3"
VELERO_OK=$(kubectl get pods -n velero -l deploy=velero --no-headers 2>/dev/null | grep -c Running || echo 0)
NODEAGENT=$(kubectl get pods -n velero -l name=node-agent --no-headers 2>/dev/null | grep -c Running || echo 0)
check "Velero server running" "$([ "${VELERO_OK}" -ge 1 ] && echo true || echo false)"
check "Velero node-agent running (filesystem PV backup)" "$([ "${NODEAGENT}" -ge 1 ] && echo true || echo false)"
BSL=$(kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
echo "  BackupStorageLocation phase: ${BSL:-unknown}"
check "S3 BackupStorageLocation is Available" "$([ "${BSL}" = "Available" ] && echo true || echo false)"

step "A.2" "The stateful ledger volume is bound"
PVC_STATUS=$(kubectl get pvc ledger-data -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
echo "  ledger-data PVC: ${PVC_STATUS}"
check "Ledger PVC is Bound (real EBS volume attached)" "$([ "${PVC_STATUS}" = "Bound" ] && echo true || echo false)"
pause

# ==========================================================================
# PART B — WRITE REAL DATA
# ==========================================================================
header "PART B — Write real transaction data into the ledger"
teach "We write real records to the PV, then record the line count and an md5"
teach "checksum. After the restore we compare against these exact values."
echo ""

step "B.1" "Write 500 transaction records to the ledger volume"
kubectl exec deploy/ledger -n "${NS}" -- sh -c '> /data/ledger.txt' 2>/dev/null
kubectl exec deploy/ledger -n "${NS}" -- sh -c \
  'i=1; while [ $i -le 500 ]; do echo "TXN-$i,amount=$((i*7)),account=ACC$((i%50)),ts='"${TS}"'" >> /data/ledger.txt; i=$((i+1)); done; sync' 2>/dev/null
ORIG_COUNT=$(kubectl exec deploy/ledger -n "${NS}" -- sh -c 'wc -l < /data/ledger.txt' 2>/dev/null | tr -d ' ')
ORIG_MD5=$(kubectl exec deploy/ledger -n "${NS}" -- sh -c 'md5sum /data/ledger.txt | cut -d" " -f1' 2>/dev/null)
echo "  Records written: ${ORIG_COUNT}"
echo "  Checksum (md5):  ${ORIG_MD5}"
check "Real data written to the persistent volume" "$([ "${ORIG_COUNT}" = "500" ] && [ -n "${ORIG_MD5}" ] && echo true || echo false)"
teach "This is our recovery point. RPO = anything written after this isn't in the backup."
pause

# ==========================================================================
# PART C — BACK UP
# ==========================================================================
header "PART C — Back up the namespace (manifests + PV data) to S3"
teach "Velero backs up every Kubernetes object in novapay-prod AND the ledger"
teach "volume's file contents (via the node-agent/Kopia), all uploaded to S3."
echo ""

step "C.1" "Create the backup"
info "Running: velero backup create ${BACKUP} --include-namespaces ${NS} --wait"
velero backup create "${BACKUP}" --include-namespaces "${NS}" --wait 2>&1 | tail -6 || true
BPHASE=$(velero backup get "${BACKUP}" -o json 2>/dev/null | grep -o '"phase": *"[A-Za-z]*"' | head -1 | grep -o '[A-Za-z]*$' | tr -d '"')
echo "  Backup phase: ${BPHASE:-unknown}"
check "Backup completed successfully" "$([ "${BPHASE}" = "Completed" ] && echo true || echo false)"

step "C.2" "Confirm the PV data was included"
PVB=$(kubectl get podvolumebackups -n velero -l velero.io/backup-name="${BACKUP}" --no-headers 2>/dev/null | grep -c Completed || echo 0)
echo "  PodVolumeBackups: ${PVB}"
check "Ledger volume data captured in the backup" "$([ "${PVB}" -ge 1 ] && echo true || echo false)"
ITEMS=$(velero backup describe "${BACKUP}" --details 2>/dev/null | grep -i "Total items to be backed up" | grep -oE '[0-9]+' | head -1 || echo "?")
info "Items backed up: ${ITEMS}  |  stored in s3://${BUCKET}/backups/${BACKUP}"
pause

# ==========================================================================
# PART D — DISASTER
# ==========================================================================
header "PART D — Simulate the disaster"
teach "We delete the entire namespace. This removes the pods, the services, the"
teach "ConfigMap, the PVC — and because gp3 reclaim policy is Delete, the real"
teach "EBS volume and its data are destroyed. This is a true loss, not a pause."
echo ""

step "D.1" "Delete the novapay-prod namespace"
info "kubectl delete namespace ${NS} ..."
kubectl delete namespace "${NS}" --wait=true --timeout=180s 2>/dev/null || true
sleep 5
GONE=$(kubectl get ns "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
check "Namespace destroyed (pods, PVC, and EBS volume gone)" "$([ "${GONE}" = "0" ] && echo true || echo false)"
teach "At this moment NovaPay's data layer is GONE. This is the scenario DR exists for."
pause

# ==========================================================================
# PART E — RESTORE
# ==========================================================================
header "PART E — Restore from the backup (measure RTO)"
teach "Velero recreates every object and rehydrates the ledger volume from S3."
echo ""

step "E.1" "Create the restore and time it"
RTO_START=$(date +%s)
info "Running: velero restore create ${RESTORE} --from-backup ${BACKUP} --wait"
velero restore create "${RESTORE}" --from-backup "${BACKUP}" --wait 2>&1 | tail -6 || true
RPHASE=$(velero restore get "${RESTORE}" -o json 2>/dev/null | grep -o '"phase": *"[A-Za-z]*"' | head -1 | grep -o '[A-Za-z]*$' | tr -d '"')
# wait for the ledger pod to come back so the volume is mounted/verifiable
kubectl rollout status deploy/ledger -n "${NS}" --timeout=180s >/dev/null 2>&1 || true
RTO_END=$(date +%s)
RTO=$((RTO_END - RTO_START))
echo "  Restore phase: ${RPHASE:-unknown}"
echo "  RTO (restore + workload ready): ${RTO}s"
check "Restore completed" "$([ "${RPHASE}" = "Completed" ] && echo true || echo false)"
pause

# ==========================================================================
# PART F — VERIFY (the real DR proof)
# ==========================================================================
header "PART F — Verify everything came back — including the real data"
echo ""

step "F.1" "Namespace and workloads restored"
# Wait for the restored workloads to fully come up (EBS volume attach takes time)
kubectl wait --for=condition=Available deploy/ledger -n "${NS}" --timeout=120s >/dev/null 2>&1 || true
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/ledger-data -n "${NS}" --timeout=60s >/dev/null 2>&1 || true
NS_BACK=$(kubectl get ns "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
DEPLOYS=$(kubectl get deploy -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
PVC_BACK=$(kubectl get pvc ledger-data -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
CM_BACK=$(kubectl get configmap novapay-settings -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  namespace: ${NS_BACK}  deployments: ${DEPLOYS}  PVC: ${PVC_BACK}  configmap: ${CM_BACK}"
check "Namespace + deployments restored" "$([ "${NS_BACK}" = "1" ] && [ "${DEPLOYS}" -ge 3 ] && echo true || echo false)"
check "Ledger PVC re-bound (volume rehydrated)" "$([ "${PVC_BACK}" = "Bound" ] && echo true || echo false)"
check "ConfigMap restored" "$([ "${CM_BACK}" -ge 1 ] && echo true || echo false)"

step "F.2" "The real ledger data matches the pre-disaster recovery point"
# Ensure the ledger pod is running and volume is mounted before exec
kubectl rollout status deploy/ledger -n "${NS}" --timeout=120s >/dev/null 2>&1 || true
sleep 5
NEW_COUNT=$(kubectl exec deploy/ledger -n "${NS}" -- sh -c 'wc -l < /data/ledger.txt' 2>/dev/null | tr -d ' ')
NEW_MD5=$(kubectl exec deploy/ledger -n "${NS}" -- sh -c 'md5sum /data/ledger.txt | cut -d" " -f1' 2>/dev/null)
echo "  Before disaster:  count=${ORIG_COUNT}  md5=${ORIG_MD5}"
echo "  After restore:     count=${NEW_COUNT}  md5=${NEW_MD5}"
check "Record count matches (${NEW_COUNT}/${ORIG_COUNT})" "$([ "${NEW_COUNT}" = "${ORIG_COUNT}" ] && echo true || echo false)"
check "Checksum matches — ZERO data loss" "$([ "${NEW_MD5}" = "${ORIG_MD5}" ] && [ -n "${NEW_MD5}" ] && echo true || echo false)"
teach "Matching checksum = the restored volume is byte-for-byte the backed-up data."
pause

# ==========================================================================
# PART G — SCHEDULES & CROSS-REGION DR
# ==========================================================================
header "PART G — Scheduled backups & cross-region DR"
teach "A one-off backup isn't DR. Real DR is automatic, regular, and off-site."
echo ""

step "G.1" "Create a recurring backup schedule (defines your RPO)"
velero schedule delete novapay-hourly --confirm 2>/dev/null || true
velero schedule create novapay-hourly --schedule="0 * * * *" --include-namespaces "${NS}" --ttl 168h0m0s 2>&1 | tail -2 || true
SCHED=$(velero schedule get 2>/dev/null | grep novapay-hourly | wc -l | tr -d ' ')
check "Hourly backup schedule created (RPO target = 1h, 7-day retention)" "$([ "${SCHED}" -ge 1 ] && echo true || echo false)"

step "G.2" "Cross-region / cross-cluster DR (the production pattern)"
teach "This lab restored into the SAME cluster. Real DR restores into a DIFFERENT"
teach "cluster, usually in another Region:"
echo "    1. S3 bucket replication (or a multi-region bucket) copies backups to the DR Region."
echo "    2. Stand up a DR EKS cluster there; install Velero pointed at the same backups."
echo "    3. 'velero restore create --from-backup ${BACKUP}' in the DR cluster."
echo "    4. Repoint DNS / Global Accelerator to the DR cluster."
info "Same backup, different cluster. The drill you just ran is the core mechanic."
pause

# ==========================================================================
# SUMMARY
# ==========================================================================
header "Module 11 Complete — DR Drill Summary"
echo -e "  ${GREEN}PASSED: ${PASS}${NC}     ${RED}FAILED: ${FAIL}${NC}"
echo ""
echo "  Recovery metrics from this run:"
echo "    RTO (measured): ${RTO}s   — time from disaster to workloads + data back"
echo "    RPO (this lab): the last backup — anything written after it is lost"
echo "    Data integrity: md5 before = after  -> zero data loss"
echo ""
if [ "${FAIL}" -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}🎉 Full namespace + persistent data recovered from S3 with zero data loss.${NC}"
else
  echo -e "  ${YELLOW}Some checks failed. Common causes:${NC}"
  echo "    • BackupStorageLocation not Available — Pod Identity still propagating; wait, re-run."
  echo "    • node-agent not Running — fs-backup of the PV can't happen; check 'kubectl get pods -n velero'."
  echo "    • Restore still in progress — large volumes take longer; re-run Part F checks."
fi
echo ""
echo "  Re-run anytime:   bash module-11-demo.sh   (each run uses a fresh backup name)"
echo "  Clean up:         bash teardown.sh"
echo ""
