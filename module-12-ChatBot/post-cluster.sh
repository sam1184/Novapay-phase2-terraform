#!/usr/bin/env bash
# NovaPay Module 12 — Post-cluster setup (Neuron plugin + vLLM + chat UI)
#
# What this script does:
#   1. Validate kubectl context
#   2. AWS Load Balancer Controller
#   3. Neuron device plugin (exposes Neuron cores as schedulable resources)
#   4. Mistral-7B served by vLLM (OpenAI-compatible inference endpoint)
#   5. Open WebUI chat front-end pointed at the vLLM endpoint
#
# NOTE: The model download (~13GB) + the ~10GB image pull in step 4 can take
#       10-15 minutes the first time.
# Usage: bash post-cluster.sh

# ===========================================================================

set -uo pipefail

REGION=$(terraform output -raw region 2>/dev/null || echo "us-east-1")
CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || echo "novapay-chatbot-lab")

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
ok()   { echo -e " ${GREEN}✔${NC} $1"; }
info() { echo -e " ${YELLOW}ℹ${NC} $1"; }

echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD} NovaPay Module 12 — Post-Cluster Setup (LLM chatbot)${NC}"
echo -e "${BOLD}============================================================${NC}"

# 1) kubeconfig ---------------------------------------------------------------
echo -e "\n${CYAN}>>> 1. Configuring kubectl for ${CLUSTER}...${NC}"
aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}" >/dev/null
kubectl cluster-info >/dev/null 2>&1 || { echo -e "${RED}Cannot reach cluster${NC}"; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null 2>&1 || true
ok "kubectl connected"
kubectl get nodes -L node.kubernetes.io/instance-type --no-headers | awk '{printf "  %-45s %s\n",$1,$6}'

# 2) AWS Load Balancer Controller ---------------------------------------------
echo -e "\n${CYAN}>>> 2. Installing AWS Load Balancer Controller...${NC}"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system --set clusterName="${CLUSTER}" \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${REGION}" --set vpcId="${VPC_ID}" --wait --timeout 180s 2>&1 | tail -2
ok "Load Balancer Controller installed"

# 3) Neuron device plugin ------------------------------------------------------
echo -e "\n${CYAN}>>> 3. Installing the Neuron device plugin...${NC}"
helm upgrade --install neuron-helm-chart \
  oci://public.ecr.aws/neuron/neuron-helm-chart \
  --namespace kube-system --version 1.5.0 \
  --set "npd.enabled=false" \
  --wait --timeout 180s 2>&1 | tail -3 || true

echo -e "  Waiting for the device plugin to expose Neuron cores on the inf2 node..."
NEURON_ALLOC=$(kubectl get nodes -o json \
  | python3 -c "
import json,sys
nodes=json.load(sys.stdin)['items']
for n in nodes:
    v=n.get('status',{}).get('allocatable',{}).get('aws.amazon.com/neuron','0')
    if v!='0': print(v); break
" 2>/dev/null || echo "")
if [[ -n "${NEURON_ALLOC}" ]]; then
  ok "Neuron cores are schedulable"
else
  info "Neuron not exposed yet — give the node a minute, re-check with: kubectl describe node -l neuron.amazonaws.com/neuron-device=true"
fi

# 4) Deploy Mistral-7B on vLLM ------------------------------------------------
echo -e "\n${CYAN}>>> 4. Deploying Mistral-7B on vLLM (this pulls a ~10GB image + downloads the model)...${NC}"

kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mistral
  namespace: vllm
  labels:
    model: mistral7b
spec:
  type: ClusterIP  # internal only — prompts never leave the VPC
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP
  selector:
    model: mistral7b
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mistral
  namespace: vllm
  labels:
    model: mistral7b
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      model: mistral7b
  template:
    metadata:
      labels:
        model: mistral7b
    spec:
      nodeSelector:
        neuron.amazonaws.com/neuron-device: "true"
      tolerations:
        - effect: NoSchedule
          key: aws.amazon.com/neuron
          operator: Exists
      initContainers:
        - name: model-download
          image: python:3.11
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              pip install -U "huggingface_hub[hf_transfer]" hf_transfer
              mkdir -p /models/mistral-7b-v0.3
              HF_HUB_ENABLE_HF_TRANSFER=1 HF_HUB_DISABLE_XET=1 huggingface-cli download \
                aws-neuron/Mistral-7B-Instruct-v0.3-seqlen-2048-bs-1-cores-2 \
                --local-dir /models/mistral-7b-v0.3
              echo "Model download complete"
          volumeMounts:
            - name: local-storage
              mountPath: /models
      containers:
        - name: vllm
          image: public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.9.1-neuronx-py311-sdk2.26.0-ubuntu22.04
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c"]
          args:
            - >
              vllm serve /models/mistral-7b-v0.3
              --tokenizer /models/mistral-7b-v0.3
              --port 8080
              --host 0.0.0.0
              --device neuron
              --tensor-parallel-size 2
              --max-num-seqs 4
              --use-v2-block-manager
              --max-model-len 2048
              --dtype bfloat16
          ports:
            - containerPort: 8080
              protocol: TCP
              name: http
          resources:
            requests:
              cpu: "3"
              memory: 12Gi
              aws.amazon.com/neuron: "1"
            limits:
              memory: 12Gi
              aws.amazon.com/neuron: "1"
          env:
            - name: NEURON_RT_NUM_CORES
              value: "2"
            - name: NEURON_RT_VISIBLE_CORES
              value: "0,1"
            - name: VLLM_NEURON_FRAMEWORK
              value: "neuronx-distributed-inference"
            - name: NEURON_COMPILED_ARTIFACTS
              value: "/models/mistral-7b-v0.3"
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 5
          volumeMounts:
            - name: dshm
              mountPath: /dev/shm
            - name: local-storage
              mountPath: /models
      terminationGracePeriodSeconds: 10
      volumes:
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 3Gi
        - name: local-storage
          emptyDir: {}
EOF

ok "vLLM Deployment + Service applied (model is loading in the background)"

# 5) Chat UI (Open WebUI) pointed at the vLLM OpenAI endpoint -----------------
echo -e "\n${CYAN}>>> 5. Deploying the chat UI (Open WebUI)...${NC}"
kubectl create namespace chatbot --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-ui
  namespace: chatbot
  labels:
    app: chat-ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: chat-ui
  template:
    metadata:
      labels:
        app: chat-ui
    spec:
      containers:
        - name: open-webui
          image: ghcr.io/open-webui/open-webui:main
          ports:
            - containerPort: 8080
          env:
            - name: OPENAI_API_BASE_URL
              value: "http://mistral.vllm:8080/v1"
            - name: OPENAI_API_KEY
              value: "novapay-local"
            - name: WEBUI_AUTH
              value: "false"
            - name: ENABLE_OLLAMA_API
              value: "false"
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: chat-ui
  namespace: chatbot
spec:
  type: ClusterIP
  selector:
    app: chat-ui
  ports:
    - port: 80
      targetPort: 8080
EOF

kubectl rollout status deploy/chat-ui -n chatbot --timeout=180s >/dev/null 2>&1 || true
ok "Chat UI deployed"

echo -e "\n${BOLD}============================================================${NC}"
echo -e " ${GREEN}Deployed.${NC} The model takes ~10-15 min to finish loading the first time."
echo -e " Watch it:  ${BOLD}kubectl get pod -n vllm -w${NC}"
echo -e " Then run:  ${BOLD}bash module-12-demo.sh${NC}"
echo -e "${BOLD}============================================================${NC}"
