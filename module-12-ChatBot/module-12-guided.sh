#!/bin/bash
# ==============================================================================
# NovaPay - Module 12: GUIDED walkthrough (manual commands, explained)
# ==============================================================================
# This sits between VALIDATE.md (pure manual) and module-12-demo.sh (pure auto).
# For each step it:
#   1. SHOWS you the exact command (what you'd type yourself — the "manual" way)
#   2. Waits for you to press ENTER (or run it yourself in another terminal)
#   3. RUNS it and shows the real output
#   4. EXPLAINS what to look for
#
# Use this to LEARN. Use module-12-demo.sh --auto when you just want a pass/fail.
#
# Usage:
#   bash module-12-guided.sh         # guided, pauses + shows commands
#   bash module-12-guided.sh --auto  # same steps, no pauses (still prints commands)
# ==============================================================================

set -uo pipefail

AUTO=false
[[ "${1:-}" == "--auto" ]] && AUTO=true

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'

# —— teaching helpers —————————————————————————————————————————————————————————
say()   { echo -e "${CYAN}$1${NC}"; }
note()  { echo -e " ${YELLOW}// $1${NC}"; }
title() { echo -e "\n${BOLD}======================================================${NC}";
          echo -e "${BOLD} $1${NC}";
          echo -e "${BOLD}======================================================${NC}"; }

# run_step "explanation of WHAT/WHY" "the command" "what to look for"
run_step() {
  local why="$1" cmd="$2" expect="$3"
  echo -e ""
  echo -e "${BLUE}— MANUAL COMMAND ————————————————————————————————————${NC}"
  echo -e "  ${BOLD}${cmd}${NC}"
  echo -e "————————————————————————————————————————————————————${NC}"
  echo -e "  ${CYAN}why:${NC} ${why}"
  if [[ "${AUTO}" != "true" ]]; then
    echo -e "  ${YELLOW}>>> Press ENTER to run it (or run it yourself in another terminal first)...${NC}"
    read -r
  fi
  echo -e "  ${GREEN}\$ ${cmd}${NC}"
  eval "${cmd}"
  echo ""
  echo -e "  ${CYAN}look for:${NC} ${expect}"
}

pause() { [[ "${AUTO}" == "true" ]] && return; echo ""; echo -e "${YELLOW}>>> Press ENTER to continue...${NC}"; read -r; }

# ==============================================================================
title "Module 12 - Guided Walkthrough (manual commands, explained)"
say "This shows you the real commands behind the automated demo, one at a time,"
say "so you learn what each piece is and how to check it yourself."
note "Automated equivalent (no learning, just pass/fail): bash module-12-demo.sh --auto"
pause

# —— 0. credentials ———————————————————————————————————————————————————————————
title "STEP 0 — Who am I? (credentials)"
run_step \
  "kubectl and aws both read the [default] profile. If this fails, your session expired — refresh it (see VALIDATE.md step 0)." \
  "aws sts get-caller-identity --query Arn --output text" \
  "an ARN ending in .../Admin/sachitri-Isengard. If you see an error, refresh creds before continuing."
pause

# —— 1. cluster ———————————————————————————————————————————————————————————————
title "STEP 1 — Can I reach the cluster, and is the accelerator there?"
run_step \
  "Lists the nodes. The whole lab hinges on one expensive accelerator node existing." \
  "kubectl get nodes -L node.kubernetes.io/instance-type" \
  "3 nodes Ready: two t3.* (system) and ONE inf2.xlarge (the Neuron accelerator)."
pause

# —— 2. device plugin / schedulable hardware ——————————————————————————————————
title "STEP 2 — Did Kubernetes learn about the Neuron hardware?"
run_step \
  "Kubernetes only knows CPU/memory by default. The Neuron device plugin advertises the chip as a schedulable resource. No plugin = the model can't get hardware." \
  "kubectl get ds neuron-device-plugin -n kube-system" \
  "the DaemonSet shows 1 desired / 1 ready (one per accelerator node)."
run_step \
  "Now confirm the node actually advertises a neuron device the scheduler can hand out." \
  "kubectl get nodes -l neuron.amazonaws.com/neuron-device=true -o jsonpath=\"{.items[0].status.allocatable.aws\\.amazon\\.com/neuron}{\"\\\n\"}\"" \
  "allocatable neuron = 1. That '1' is what the model pod requests."
pause

# —— 3. the model pod —————————————————————————————————————————————————————————
title "STEP 3 — Is the model running, and on the RIGHT node?"
run_step \
  "The vLLM pod must land on the inf2 node (via nodeSelector + toleration). Check it's Running and which node it's on." \
  "kubectl get pods -n vllm -o wide" \
  "mistral-... pod 1/1 Running, on the inf2.xlarge node's IP (matches step 1)."
run_step \
  "Look at the server's own logs to see it actually serving HTTP." \
  "kubectl logs deploy/mistral -n vllm -c vllm | tail -8" \
  "Lines like 'Application startup complete' and 'GET /health 200 OK'."
pause

# —— 4. the API ———————————————————————————————————————————————————————————————
title "STEP 4 — Does it expose the OpenAI-compatible API?"
note "We call the API from a throwaway pod INSIDE the cluster (kubectl run). That's"
note "more reliable than a port-forward AND it proves the prompt never leaves the VPC."
run_step \
  "Ask the model server what model it's serving — the OpenAI /v1/models endpoint." \
  "kubectl run q-models-$$ --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n vllm --quiet -- curl -s http://mistral.vllm:8080/v1/models" \
  "JSON listing model id /models/mistral-7b-v0.3."
pause

# —— 5. REAL inference ————————————————————————————————————————————————————————
title "STEP 5 — Real inference (the actual proof)"
run_step \
  "Send a real support question to /v1/chat/completions and read the generated answer." \
  "kubectl run q-charge-$$ --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n vllm --quiet -- curl -s http://mistral.vllm:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"/models/mistral-7b-v0.3\",\"messages\":[{\"role\":\"user\",\"content\":\"In one sentence, what is a payment chargeback?\"}],\"max_tokens\":60}'" \
  "a JSON response whose choices[0].message.content is a real sentence about chargebacks. (First call can take 10-30s if the pod was idle.)"
pause

# —— 6. the lesson question ———————————————————————————————————————————————————
title "STEP 6 — The most important lesson: it knows nothing about NovaPay"
run_step \
  "Ask about something only NovaPay would know. Watch what a BASE model does with it." \
  "kubectl run q-novapay-$$ --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n vllm --quiet -- curl -s http://mistral.vllm:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"/models/mistral-7b-v0.3\",\"messages\":[{\"role\":\"user\",\"content\":\"What is NovaPay'\\''s exact refund policy?\"}],\"max_tokens\":80}'" \
  "a confident but MADE-UP answer. The model has never seen NovaPay's docs — it hallucinates. THIS is why you need RAG (grounding it on real data). The lab serves the model; it does not give it your knowledge."
pause

# —— 7. data residency ————————————————————————————————————————————————————————
title "STEP 7 — Data residency (the banking reason to self-host)"
run_step \
  "Confirm the model has NO public endpoint. The whole point: prompts stay in-VPC." \
  "kubectl get svc mistral -n vllm" \
  "TYPE = ClusterIP, EXTERNAL-IP = <none>. Nothing on the public internet can reach the model."
pause

# —— 8. the UI ————————————————————————————————————————————————————————————————
title "STEP 8 — The chat UI"
say "The UI is also internal (ClusterIP). To use it from your laptop, open a tunnel:"
echo -e "  ${BOLD}kubectl port-forward svc/chat-ui -n chatbot 8080:80${NC}"
say "Leave it running, then open http://localhost:8080 and chat with the mistral model."
note "If the browser shows nothing, the port-forward died (usually expired creds) —"
note "refresh creds (VALIDATE.md step 0) and run the port-forward again."
run_step \
  "Confirm the UI deployment is healthy (it talks to the model via the OpenAI API)." \
  "kubectl get deploy chat-ui -n chatbot" \
  "chat-ui shows 1/1 READY."
pause

# —— wrap —————————————————————————————————————————————————————————————————————
title "Done — what you just learned"
echo "  * An LLM on EKS = accelerator node + device plugin + a model server (vLLM)."
echo "  * vLLM speaks the OpenAI API, so any UI/client works against it unchanged."
echo "  * The model is internal-only (ClusterIP) — prompts never leave the VPC."
echo "  * A base model answers general knowledge well, but hallucinates anything"
echo "    NovaPay-specific. Grounding it on your data (RAG) is the next module."
echo ""
echo -e "  Manual reference:    ${BOLD}VALIDATE.md${NC}"
echo -e "  Automated pass/fail: ${BOLD}bash module-12-demo.sh --auto${NC}"
echo -e "  ${BOLD}COST:${NC} the inf2.xlarge bills ~\$0.76/hr — bash teardown.sh when done."
echo ""
