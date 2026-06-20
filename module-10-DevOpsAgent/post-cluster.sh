#!/bin/bash
# =============================================================================
# NovaPay Module 10 - Post-cluster setup  (REAL apps, REAL data)
#
# Deploys the platform the DevOps Agent operates on. Everything here produces
# REAL signals - there is NO synthetic/injected metric or log anywhere:
#
#   - auth-service   : a real HTTP app that issues tokens in a configurable format
#   - payment-service: a real HTTP app that validates tokens; on a format mismatch
#                       it returns a real HTTP 502 and logs a real "token parse error".
#                       A sidecar counts ACTUAL request outcomes from the access log
#                       and publishes them via cloudwatch:PutMetricData (Pod Identity).
#   - traffic-generator: real continuous login->charge traffic (real 200s / 502s)
#   - ArgoCD + LB controller + Container Insights (real metrics + logs to CloudWatch)
#
# Idempotent: safe to run many times (kubectl apply / create --dry-run).
#
# Usage: bash post-cluster.sh
# =============================================================================

set -uo pipefail

REGION=$(terraform output -raw region 2>/dev/null || echo "us-east-1")
CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || echo "novapay-devops-agent-lab")
METRIC_NS=$(terraform output -raw metric_namespace 2>/dev/null || echo "NovaPay/payment-service")
NS="novapay-prod"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
ok(){ echo -e "  ${GREEN}✅${NC} $1"; }
info(){ echo -e "  ${YELLOW}ℹ${NC}  $1"; }

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  NovaPay Module 10 - Post-Cluster Setup (real apps)${NC}"
echo -e "${BOLD}================================================================${NC}"

# 1) kubeconfig ----------------------------------------------------------------
echo -e "\n${CYAN}>>> 1. Configuring kubectl for ${CLUSTER}...${NC}"
aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}" >/dev/null
kubectl cluster-info >/dev/null 2>&1 || { echo -e "${RED}Cannot reach cluster${NC}"; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=240s >/dev/null 2>&1 || true
ok "kubectl connected; nodes Ready"

# 2) AWS Load Balancer Controller ----------------------------------------------
echo -e "\n${CYAN}>>> 2. Installing AWS Load Balancer Controller...${NC}"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system --set clusterName="${CLUSTER}" \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${REGION}" --set vpcId="${VPC_ID}" --wait --timeout 180s 2>&1 | tail -2
ok "Load Balancer Controller installed"

# 3) ArgoCD ----------------------------------------------------------------
echo -e "\n${CYAN}>>> 3. Installing ArgoCD (GitOps delivery engine)...${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null 2>&1
info "Waiting for ArgoCD server (up to 3 min)..."
kubectl rollout status deploy/argocd-server -n argocd --timeout=180s >/dev/null 2>&1 || true
ok "ArgoCD installed ($(kubectl get pods -n argocd --no-headers 2>/dev/null | grep -c Running) pods running)"

# 4) Namespace + service account ----------------------------------------------
echo -e "\n${CYAN}>>> 4. Creating namespace + payment-sa (Pod Identity for real metrics)...${NC}"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create serviceaccount payment-sa -n "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "Namespace + payment-sa ready"

# 5) Real application code (no build needed - stdlib Python, mounted via ConfigMap)
echo -e "\n${CYAN}>>> 5. Deploying the REAL NovaPay apps...${NC}"
APPDIR=$(mktemp -d)
cat > "${APPDIR}/app.py" <<'PYEOF'
import os, json, time, random
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = os.environ.get("ROLE", "payment")
TOKEN_FORMAT = os.environ.get("TOKEN_FORMAT", "v1")            # payment expects this
AUTH_TOKEN_FORMAT = os.environ.get("AUTH_TOKEN_FORMAT", "v1")  # auth issues this
ACCESS_LOG = "/var/log/app/access.log"

def log_json(level, msg, **kw):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "level": level, "service": ROLE, "msg": msg}
    rec.update(kw)
    print(json.dumps(rec), flush=True)

def access(status):
    try:
        with open(ACCESS_LOG, "a") as f:
            f.write("%d %d\n" % (int(time.time()), status))
    except Exception:
        pass

class H(BaseHTTPRequestHandler):
    def _send(self, code, body=""):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        if body:
            self.wfile.write(body.encode())
    def log_message(self, *a):
        pass
    def do_GET(self):
        if self.path.startswith("/healthz") or self.path == "/":
            return self._send(200, "ok")
        if ROLE == "auth" and self.path.startswith("/login"):
            token = "%s.%s" % (AUTH_TOKEN_FORMAT, "%08x" % random.getrandbits(32))
            return self._send(200, token)
        return self._charge()
    def do_POST(self):
        return self._charge()
    def _charge(self):
        if ROLE != "payment" or not self.path.startswith("/charge"):
            return self._send(404, "not found")
        token = self.headers.get("X-Auth-Token", "")
        ver = token.split(".")[0] if token else "none"
        if ver != TOKEN_FORMAT:
            access(502)
            log_json("error", "token parse error", expected=TOKEN_FORMAT, got=ver,
                      request_id="req-%08x" % random.getrandbits(32))
            return self._send(502, "token parse error")
        access(200)
        return self._send(200, "charged")

log_json("info", "%s starting" % ROLE, expected=TOKEN_FORMAT, issues=AUTH_TOKEN_FORMAT)
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
PYEOF

# Metrics sidecar: counts REAL outcomes from the access log, publishes real counts.
cat > "${APPDIR}/publish.sh" <<'SHEOF'
#!/bin/sh
LOG=/var/log/app/access.log
touch "$LOG" 2>/dev/null || true
echo "metrics-publisher started; namespace=${METRIC_NS} region=${AWS_DEFAULT_REGION}"
while true; do
  sleep 60
  TOTAL=$(wc -l < "$LOG" 2>/dev/null | tr -d ' '); [ -z "$TOTAL" ] && TOTAL=0
  ERR=$(grep -c ' 502$' "$LOG" 2>/dev/null | tr -d ' '); [ -z "$ERR" ] && ERR=0
  : > "$LOG" 2>/dev/null || true
  if [ "$TOTAL" -gt 0 ]; then
    aws cloudwatch put-metric-data --namespace "${METRIC_NS}" \
      --metric-data MetricName=HttpRequestCount,Value="$TOTAL",Unit=Count \
                    MetricName=Http5xxCount,Value="$ERR",Unit=Count >/dev/null 2>&1 \
      && echo "published requests=$TOTAL 5xx=$ERR" || echo "publish failed (will retry)"
  fi
done
SHEOF

kubectl create configmap payment-app -n "${NS}" --from-file=app.py="${APPDIR}/app.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create configmap payment-metrics -n "${NS}" --from-file=publish.sh="${APPDIR}/publish.sh" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -rf "${APPDIR}"
ok "App + metrics-publisher ConfigMaps applied"

# 6) Deployments + services ----------------------------------------------------
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: auth-service, namespace: novapay-prod, labels: { app: auth-service, tier: identity } }
spec:
  replicas: 2
  selector: { matchLabels: { app: auth-service } }
  template:
    metadata: { labels: { app: auth-service, tier: identity } }
    spec:
      containers:
        - name: auth-service
          image: public.ecr.aws/docker/library/python:3.11-slim
          command: ["python","/app/app.py"]
          env:
            - { name: ROLE, value: "auth" }
            - { name: AUTH_TOKEN_FORMAT, value: "v1" }
          ports: [{ containerPort: 8080 }]
          volumeMounts: [{ name: app, mountPath: /app }]
          readinessProbe: { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 3, periodSeconds: 5 }
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 250m, memory: 128Mi } }
      volumes: [{ name: app, configMap: { name: payment-app } }]
---
apiVersion: v1
kind: Service
metadata: { name: auth-service, namespace: novapay-prod }
spec: { selector: { app: auth-service }, ports: [{ port: 80, targetPort: 8080 }] }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: novapay-prod
  labels: { app: payment-service, tier: money }
  annotations: { novapay.io/version: "v1.0.0", argocd.argoproj.io/managed: "true" }
spec:
  replicas: 3
  selector: { matchLabels: { app: payment-service } }
  template:
    metadata: { labels: { app: payment-service, tier: money } }
    spec:
      serviceAccountName: payment-sa
      containers:
        - name: payment-service
          image: public.ecr.aws/docker/library/python:3.11-slim
          command: ["python","/app/app.py"]
          env:
            - { name: ROLE, value: "payment" }
            - { name: TOKEN_FORMAT, value: "v1" }
          ports: [{ containerPort: 8080 }]
          volumeMounts:
            - { name: app, mountPath: /app }
            - { name: accesslog, mountPath: /var/log/app }
          readinessProbe: { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 3, periodSeconds: 5 }
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 250m, memory: 128Mi } }
        - name: metrics-publisher
          image: public.ecr.aws/aws-cli/aws-cli:latest
          command: ["sh","/scripts/publish.sh"]
          env:
            - { name: AWS_DEFAULT_REGION, value: "${REGION}" }
            - { name: METRIC_NS, value: "${METRIC_NS}" }
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
            - { name: accesslog, mountPath: /var/log/app }
          resources: { requests: { cpu: 25m, memory: 48Mi }, limits: { cpu: 100m, memory: 96Mi } }
      volumes:
        - { name: app, configMap: { name: payment-app } }
        - { name: scripts, configMap: { name: payment-metrics } }
        - { name: accesslog, emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata: { name: payment-service, namespace: novapay-prod }
spec: { selector: { app: payment-service }, ports: [{ port: 80, targetPort: 8080 }] }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: webhook-service, namespace: novapay-prod, labels: { app: webhook-service, tier: edge } }
spec:
  replicas: 2
  selector: { matchLabels: { app: webhook-service } }
  template:
    metadata: { labels: { app: webhook-service, tier: edge } }
    spec:
      containers:
        - name: webhook-service
          image: public.ecr.aws/docker/library/python:3.11-slim
          command: ["python","/app/app.py"]
          env: [{ name: ROLE, value: "webhook" }]
          ports: [{ containerPort: 8080 }]
          volumeMounts: [{ name: app, mountPath: /app }]
          readinessProbe: { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 3, periodSeconds: 5 }
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 200m, memory: 128Mi } }
      volumes: [{ name: app, configMap: { name: payment-app } }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: kyc-service, namespace: novapay-prod, labels: { app: kyc-service, tier: identity } }
spec:
  replicas: 1
  selector: { matchLabels: { app: kyc-service } }
  template:
    metadata: { labels: { app: kyc-service, tier: identity } }
    spec:
      containers:
        - name: kyc-service
          image: public.ecr.aws/docker/library/python:3.11-slim
          command: ["python","/app/app.py"]
          env: [{ name: ROLE, value: "kyc" }]
          ports: [{ containerPort: 8080 }]
          volumeMounts: [{ name: app, mountPath: /app }]
          readinessProbe: { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 3, periodSeconds: 5 }
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 200m, memory: 128Mi } }
      volumes: [{ name: app, configMap: { name: payment-app } }]
EOF
kubectl rollout status deploy/payment-service -n "${NS}" --timeout=180s || true
kubectl rollout status deploy/auth-service -n "${NS}" --timeout=120s || true
ok "Real NovaPay services running"
kubectl get pods -n "${NS}" --no-headers | awk '{printf "  %-50s %s\n",$1,$3}'

# 7) Real, continuous traffic (login -> charge) ---------------------------------
echo -e "\n${CYAN}>>> 7. Starting REAL continuous traffic (auth login -> payment charge)...${NC}"
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: traffic-generator, namespace: novapay-prod, labels: { app: traffic-generator, novapay.io/infra: "true" } }
spec:
  replicas: 2
  selector: { matchLabels: { app: traffic-generator } }
  template:
    metadata: { labels: { app: traffic-generator, novapay.io/infra: "true" } }
    spec:
      containers:
        - name: gen
          image: curlimages/curl:8.10.1
          command:
            - /bin/sh
            - -c
            - |
              echo "traffic-generator started"
              while true; do
                TOKEN=$(curl -s --max-time 3 http://auth-service.novapay-prod/login 2>/dev/null)
                CODE=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" \
                  -H "X-Auth-Token: ${TOKEN}" \
                  http://payment-service.novapay-prod/charge 2>/dev/null)
                echo "charge -> ${CODE}"
                sleep 1
              done
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { cpu: 50m, memory: 64Mi } }
EOF
ok "Traffic generator running (real requests every ~1s)"

# 8) Verify Container Insights (real metrics+logs to CloudWatch) ----------------
echo -e "\n${CYAN}>>> 8. Verifying CloudWatch Observability (Container Insights)...${NC}"
kubectl rollout status daemonset/cloudwatch-agent -n amazon-cloudwatch --timeout=120s >/dev/null 2>&1 || true
CWA=$(kubectl get pods -n amazon-cloudwatch --no-headers 2>/dev/null | grep -c Running || true); CWA=${CWA:-0}
if [ "${CWA}" -ge 1 ]; then
  ok "Container Insights agent running (${CWA} pods) - real logs/metrics to CloudWatch"
else
  info "CloudWatch agent still starting; re-check in a minute: kubectl get pods -n amazon-cloudwatch"
fi

echo -e "\n${BOLD}================================================================${NC}"
echo -e "  ${GREEN}Platform ready with REAL traffic flowing.${NC}"
echo -e "  Let metrics flow for ~2 min, then run:"
echo -e "    ${BOLD}bash module-10-demo.sh${NC}        (interactive)"
echo -e "    ${BOLD}bash module-10-demo.sh --auto${NC}  (CI)"
echo -e "${BOLD}================================================================${NC}"
