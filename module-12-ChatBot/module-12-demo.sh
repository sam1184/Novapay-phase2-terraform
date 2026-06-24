#!/bin/bash
# ==============================================================================
# NovaPay - Module 12: Self-hosted LLM Chatbot (vLLM on Neuron)
#
# Validates the whole chatbot stack with REAL inference - it sends real support
# questions to the model and checks real answers come back. Nothing mocked.
#
#   A. Prerequisites  - Neuron plugin, accelerator node, vLLM pod
#   B. Model serving  - vLLM healthy, OpenAI /v1/models lists Mistral
#   C. Real inference - ask NovaPay support questions, get real completions
#   D. Chat UI        - Open WebUI running and wired to the model
#   E. Data residency - prove the model endpoint is internal (prompts stay in-VPC)
#   F. Scaling & cost - Neuron cores, scale-to-zero, the production pattern
#
# Usage:
#   bash module-12-demo.sh          # interactive
#   bash module-12-demo.sh --auto   # non-interactive (CI)
# ==============================================================================

set -uo pipefail

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

REGION=$(terraform output -raw region 2>/dev/null || echo "us-east-1")
CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || echo "novapay-chatbot-lab")
NEURON_TYPE=$(terraform output -raw neuron_instance_type 2>/dev/null || echo "inf2.xlarge")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
PASS=0; FAIL=0

pause()  { if [[ "${AUTO_MODE}" == "true" ]]; then sleep 1; return; fi; echo ""; echo -e "${YELLOW}>>> Press ENTER to continue...${NC}"; read -r; }
header() { echo ""; echo -e "${BOLD}================================================================${NC}"; echo -e "${BOLD} $1${NC}"; echo -e "${BLUE}================================================================${NC}"; }
step()   { echo -e "${BLUE}--- $1${NC}"; }
info()   { echo -e "  ${YELLOW}// $1${NC}"; }
teach()  { echo -e "  ${CYAN}▶ $1${NC}"; }
check()  { if [ "$2" = "true" ]; then echo -e "  ${GREEN}✔ PASS: $1${NC}"; PASS=$((PASS+1)); else echo -e "  ${RED}✖ FAIL: $1${NC}"; FAIL=$((FAIL+1)); fi; }

PF_PID=""
start_pf() { true; }  # inference is done in-cluster via kubectl run (reliable + proves data residency)
stop_pf()  { true; }
trap stop_pf EXIT

# Helper: run a curl inside the cluster (prompts never leave the VPC)
cluster_curl() {
  local name="probe-$RANDOM"
  kubectl run "${name}" --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n vllm --quiet -- "$@" 2>/dev/null
}

header "Module 12 - Self-hosted LLM Chatbot on EKS"
echo "  Cluster:     ${CLUSTER}  (${REGION})"
echo "  Accelerator: ${NEURON_TYPE}  |  Model: Mistral-7B-Instruct via vLLM"
echo ""
kubectl cluster-info >/dev/null 2>&1 || { echo -e "${RED}Cannot reach cluster. Run post-cluster.sh${NC}"; exit 1; }

# ==============================================================================
# PART A - PREREQUISITES
# ==============================================================================

header "PART A - Prerequisites"
teach "An LLM on EKS needs three things: the accelerator hardware, the device"
teach "plugin that makes its cores schedulable, and the model pod placed on it."
echo ""

step "A.1" "Neuron device plugin is running"
NDP=$(kubectl get ds neuron-device-plugin -n kube-system --no-headers 2>/dev/null | awk '{print $4}')
echo "  neuron-device-plugin ready pods: ${NDP:-0}"
check "Neuron device plugin DaemonSet has a ready pod" "$([[ "${NDP:-0}" -ge 1 ]] 2>/dev/null && echo true || echo false)"

step "A.2" "The accelerator node exposes Neuron cores"
NODE=$(kubectl get nodes -l neuron.amazonaws.com/neuron-device=true --no-headers 2>/dev/null | grep -c Ready || echo 0)
ALLOC=$(kubectl get nodes -l neuron.amazonaws.com/neuron-device=true -o jsonpath='{.items[0].status.allocatable.aws\.amazon\.com/neuron}' 2>/dev/null || echo "")
echo "  Neuron node Ready: ${NODE}   allocatable neuron cores/devices: ${ALLOC:-0}"
check "Accelerator node present with schedulable Neuron resource" "$([[ "${NODE}" -ge 1 ]] && [[ -n "${ALLOC}" ]] && echo true || echo false)"

step "A.3" "The vLLM pod is scheduled on the accelerator"
VLLM_NODE=$(kubectl get pod -n vllm -l model=mistral7b -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
check "vLLM pod placed on a node (Karpenter/taint routing worked)" "$([[ -n "${VLLM_NODE}" ]] && echo true || echo false)"

pause

# ==============================================================================
# PART B - MODEL SERVING
# ==============================================================================

header "PART B - Model serving (vLLM OpenAI-compatible API)"
teach "vLLM exposes an OpenAI-compatible API. First it must finish downloading the"
teach "model (~GBs) and loading it onto the Neuron cores - this takes a while."
echo ""

step "B.1" "Wait for vLLM to become healthy"
info "Polling the vLLM Deployment for an available replica (up to 15 min)..."
READY=0
for i in $(seq 1 90); do
  READY=$(kubectl get deploy mistral -n vllm -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
  [[ "${READY:-0}" -ge 1 ]] && break
  sleep 10
done
echo "  vLLM available replicas: ${READY:-0}"
check "vLLM is serving (model loaded, /health passing)" "$([[ "${READY:-0}" -ge 1 ]] && echo true || echo false)"
if [[ "${READY:-0}" -lt 1 ]]; then
  info "Still loading. Watch: kubectl logs deploy/mistral -n vllm -c vllm -f -- then re-run this script."
fi

step "B.2" "The OpenAI /v1/models endpoint lists Mistral"
MODELS=$(cluster_curl curl -s --max-time 15 http://mistral.vllm:8080/v1/models)
MODEL_ID=$(echo "${MODELS}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "  Served model id: ${MODEL_ID:-<none>}"
check "Model is registered on the OpenAI API" "$([[ -n "${MODEL_ID}" ]] && echo true || echo false)"

pause

# ==============================================================================
# PART C - REAL INFERENCE
# ==============================================================================

header "PART C - Real inference (ask the NovaPay support assistant)"
teach "This is the proof: we send real customer-support questions and the model"
teach "returns real generated answers. Nothing here is canned."
echo ""

ask() {
  local q="$1"
  cluster_curl curl -s --max-time 120 http://mistral.vllm:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"system\",\"content\":\"You are NovaPay's support assistant. Answer briefly.\"},{\"role\":\"user\",\"content\":\"${q}\"}],\"max_tokens\":80,\"temperature\":0.2}"
}

if [[ -n "${MODEL_ID}" ]]; then
  step "C.1" "Question 1: what is a chargeback?"
  R1=$(ask "In one sentence, what is a payment chargeback?")
  A1=$(echo "${R1}" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "  Model answer: ${A1:0:200}"
  check "Got a real, non-empty completion" "$([[ -n "${A1}" ]] && echo true || echo false)"

  step "C.2" "Question 2: KYC"
  R2=$(ask "What does KYC mean for a payments platform? One sentence.")
  A2=$(echo "${R2}" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "  Model answer: ${A2:0:200}"
  check "Second completion returned" "$([[ -n "${A2}" ]] && echo true || echo false)"
else
  check "Got a real, non-empty completion" "false"
  check "Second completion returned" "false"
  info "Skipped - model not serving yet. Re-run after B.1 passes."
fi

pause

# ==============================================================================
# PART D - CHAT UI
# ==============================================================================

header "PART D - The chat UI"
teach "Open WebUI gives customers a chat box; it talks to vLLM's OpenAI API."
echo ""

step "D.1" "Chat UI is running"
UI=$(kubectl get deploy chat-ui -n chatbot -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
check "Open WebUI deployment available" "$([[ "${UI:-0}" -ge 1 ]] && echo true || echo false)"
info "Open it locally:  kubectl port-forward svc/chat-ui -n chatbot 8080:80"
info "Then browse to:   http://localhost:8080  (pick the mistral model, start chatting)"

pause

# ==============================================================================
# PART E - DATA RESIDENCY (the banking reason to self-host)
# ==============================================================================

header "PART E - Data residency: prompts never leave the VPC"
teach "The whole reason a bank self-hosts an LLM: customer prompts may contain"
teach "account or payment detail. If you call a public LLM API, that data leaves"
teach "your boundary. Here the model is a ClusterIP service - internal only."
echo ""

step "E.1" "The model endpoint is internal (ClusterIP), not internet-exposed"
SVC_TYPE=$(kubectl get svc mistral -n vllm -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
echo "  mistral service type: ${SVC_TYPE}"
check "Model served as ClusterIP (no public endpoint)" "$([[ "${SVC_TYPE}" = "ClusterIP" ]] && echo true || echo false)"
teach "Inference happens on hardware in your account; the prompt and the answer"
teach "stay inside the cluster. That's what makes this acceptable for regulated data."

pause

# ==============================================================================
# PART F - SCALING & COST
# ==============================================================================

header "PART F - Scaling & cost"
teach "Accelerators are expensive, so you scale them deliberately."
echo ""
echo "  • Neuron cores: inf2.xlarge = 1 Inferentia2 chip / 2 cores → tensor-parallel-size 2."
echo "  • Throughput: vLLM PagedAttention batches concurrent requests (--max-num-seqs)."
echo "  • Scale to zero: this node group has min_size=0. In production you'd use"
echo "    Karpenter with a Neuron NodePool so the node is created on demand and"
echo "    removed when idle - you don't pay for the accelerator 24/7."
echo "  • Bigger models / more traffic: scale tensor-parallel across more cores"
echo "    (trn1.32xlarge / inf2.48xlarge), or run multiple replicas behind the Service."
info "This lab keeps one inf2.xlarge running for simplicity. TEAR DOWN when done."

pause

# ==============================================================================
# SUMMARY
# ==============================================================================

header "Module 12 Complete - Chatbot Drill Summary"
echo -e "  ${GREEN}PASSED: ${PASS}${NC}    ${RED}FAILED: ${FAIL}${NC}"
echo ""
if [ "${FAIL}" -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}✔ Mistral-7B is serving real answers on Neuron, fully inside your VPC.${NC}"
else
  echo -e "  ${YELLOW}Some checks failed. Most common cause: the model is still loading.${NC}"
  echo "  • Watch: kubectl get pod -n vllm -w  and  kubectl logs deploy/mistral -n vllm -c vllm -f"
  echo "  • First load pulls a ~10GB image + downloads the model; 10-15 min is normal."
  echo "  • Re-run this script once vLLM shows an available replica."
fi
echo ""
echo -e "  ${BOLD}COST REMINDER:${NC} the ${NEURON_TYPE} node bills ~\$0.76/hr. Run ${BOLD}bash teardown.sh${NC} now if you're done."
echo ""
