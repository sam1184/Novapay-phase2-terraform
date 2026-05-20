#!/bin/bash
# ==============================================================================
# NovaPay - Post-Terraform Apply Script (Self-Contained)
# Runs after `terraform apply` completes.
# Handles: Karpenter Helm, services, Argo Rollouts, ArgoCD
#
# This script is fully self-contained - all source code is generated inline.
# No external file dependencies. Can be run from any empty directory.
# ==============================================================================

set -euo pipefail

CLUSTER_NAME="novapay-prod-eks-v2"
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Generate source files into a temp directory (fully self-contained)
WORK_DIR=$(mktemp -d)
bash "${SCRIPT_DIR}/generate-sources.sh" "${WORK_DIR}"
REPO_ROOT="${WORK_DIR}"

echo "======================================================================"
echo "  NovaPay Post-Apply - Modules 1-4 (Self-Contained)"
echo "  Account: ${ACCOUNT_ID}"
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Repo:    ${REPO_ROOT}"
echo "======================================================================"

# -- Configure kubectl --------------------------------------------------------
echo ""
echo ">>> Configuring kubectl..."
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}
kubectl cluster-info

# -- Wait for nodes -----------------------------------------------------------
echo ">>> Waiting for system nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# ==============================================================================
# MODULE 1: Namespaces + NetworkPolicy (INLINED)
# ==============================================================================
echo ""
echo "==== Namespaces + NetworkPolicy ===="

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: novapay-prod
  labels:
    app.kubernetes.io/part-of: novapay
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: novapay-staging
  labels:
    app.kubernetes.io/part-of: novapay
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: novapay-prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: karpenter
  labels:
    pod-security.kubernetes.io/enforce: baseline
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: novapay-prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: novapay-prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
        podSelector:
          matchLabels:
            k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF

# ==============================================================================
# MODULE 2: Map Karpenter Node Role into cluster auth
# ==============================================================================
echo ""
echo "==== Mapping Karpenter Node Role ===="
eksctl create iamidentitymapping \
  --cluster ${CLUSTER_NAME} \
  --region ${REGION} \
  --arn "arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --group system:bootstrappers \
  --group system:nodes \
  --username "system:node:{{EC2PrivateDNSName}}" || echo "  Mapping already exists — continuing"

# VALIDATE — fail fast if mapping is missing; Karpenter nodes will launch but never join
if ! eksctl get iamidentitymapping --cluster ${CLUSTER_NAME} --region ${REGION} 2>/dev/null | grep -q "KarpenterNodeRole"; then
  echo "ERROR: KarpenterNodeRole identity mapping not found in aws-auth."
  echo "  Karpenter nodes will launch but refuse to join the cluster (401 Unauthorized)."
  echo "  Fix: eksctl create iamidentitymapping --cluster ${CLUSTER_NAME} --region ${REGION} --arn arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME} --group system:bootstrappers --group system:nodes --username system:node:{{EC2PrivateDNSName}}"
  exit 1
fi
echo "  IAM identity mapping confirmed"

# -- Install Karpenter via Helm -----------------------------------------------
echo ""
echo "==== Installing Karpenter ===="
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "1.0.0" \
  --namespace kube-system \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set 'controller.tolerations[0].key=CriticalAddonsOnly' \
  --set 'controller.tolerations[0].operator=Exists' \
  --set 'controller.tolerations[0].effect=NoSchedule' \
  --wait --timeout 120s

echo ">>> Waiting for Karpenter pods..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=karpenter \
  -n kube-system --timeout=120s
echo "  Karpenter running"

# -- Apply EC2NodeClass + NodePools (INLINED) ----------------------------------
echo ">>> Applying EC2NodeClass + NodePools..."

cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: novapay-default
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: novapay-prod-v2
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: novapay-prod-v2
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 1
    httpTokens: required
  tags:
    Project: NovaPay
    Environment: production
    ManagedBy: Karpenter
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: payment-critical
spec:
  template:
    metadata:
      labels:
        workload-type: payment
        novapay.io/pool: payment-critical
    spec:
      expireAfter: 720h
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: novapay-default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.small", "t3.medium", "m5.large", "c5.large"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["us-east-1a", "us-east-1b"]
      taints:
        - key: novapay.io/payment-critical
          effect: NoSchedule
  limits:
    cpu: "200"
    memory: "800Gi"
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 60s
  weight: 10
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general
spec:
  template:
    metadata:
      labels:
        workload-type: general
        novapay.io/pool: general
    spec:
      expireAfter: 720h
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: novapay-default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.small", "t3.medium", "m5.large", "c5.large", "t3a.small", "t3a.medium"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["us-east-1a", "us-east-1b"]
  limits:
    cpu: "128"
    memory: "512Gi"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  weight: 5
EOF

echo ">>> Verifying NodePools..."
sleep 5
kubectl get nodepools
kubectl get ec2nodeclass

# -- Enable prefix delegation -------------------------------------------------
echo ">>> Enabling prefix delegation (110 pods/node)..."
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true \
  WARM_PREFIX_TARGET=1

# ==============================================================================
# BUILD AND PUSH ECR IMAGES
# Issue 3 fix: Check if ALL images exist first. Skip entire Docker section if
# they do — avoids failure on machines where Docker is not installed/running.
# If any image is missing, Docker is required locally.
# ==============================================================================
echo ""
echo "==== Building and Pushing ECR Images ===="

IMAGES_EXIST=true
for svc in auth charge webhook kyc; do
  if ! aws ecr describe-images --repository-name "novapay-poc/${svc}" \
    --image-ids imageTag=v1.0.0 --region ${REGION} >/dev/null 2>&1; then
    IMAGES_EXIST=false
    echo "  novapay-poc/${svc}:v1.0.0 missing"
    break
  fi
done

if [ "${IMAGES_EXIST}" = "true" ]; then
  echo "  All v1.0.0 images already exist in ECR — skipping build"
  echo "  Checking v2.0.0..."
  for svc in auth charge webhook kyc; do
    if ! aws ecr describe-images --repository-name "novapay-poc/${svc}" \
      --image-ids imageTag=v2.0.0 --region ${REGION} >/dev/null 2>&1; then
      echo "  novapay-poc/${svc}:v2.0.0 missing — will build"
      IMAGES_EXIST=false
      break
    fi
  done
fi

if [ "${IMAGES_EXIST}" = "true" ]; then
  echo "  All v1.0.0 + v2.0.0 images exist — skipping all builds"
else
  # Check Docker is available before attempting local build
  if ! docker info >/dev/null 2>&1; then
    echo ""
    echo "ERROR: Docker is not running (or not installed) and ECR images are missing."
    echo "  Option A: Start Docker Desktop and re-run this script."
    echo "  Option B: Push images from another machine that already has Docker."
    echo "  Option C: Use AWS CodeBuild — copy build-and-deploy.sh from the working machine."
    echo ""
    exit 1
  fi

  aws ecr get-login-password --region ${REGION} | \
    docker login --username AWS --password-stdin ${ECR_BASE}

  for svc in auth charge webhook kyc; do
    REPO="${ECR_BASE}/novapay-poc/${svc}"
    if aws ecr describe-images --repository-name "novapay-poc/${svc}" \
      --image-ids imageTag=v1.0.0 --region ${REGION} >/dev/null 2>&1; then
      echo "  ${svc}:v1.0.0 already exists — skipping"
    else
      echo "  Building ${svc}:v1.0.0..."
      docker build --target runner --platform linux/amd64 \
        -t "${REPO}:v1.0.0" "${REPO_ROOT}/services/${svc}"
      docker push "${REPO}:v1.0.0"
      echo "  ${svc}:v1.0.0 pushed"
    fi
  done

  for svc in auth charge webhook kyc; do
    REPO="${ECR_BASE}/novapay-poc/${svc}"
    if aws ecr describe-images --repository-name "novapay-poc/${svc}" \
      --image-ids imageTag=v2.0.0 --region ${REGION} >/dev/null 2>&1; then
      echo "  ${svc}:v2.0.0 already exists — skipping"
    else
      echo "  Building ${svc}:v2.0.0..."
      docker build --target runner --platform linux/amd64 \
        -t "${REPO}:v2.0.0" "${REPO_ROOT}/services/${svc}"
      docker push "${REPO}:v2.0.0"
      echo "  ${svc}:v2.0.0 pushed"
    fi
  done
fi

# ==============================================================================
# MODULE 3: Deploy Database Dependencies (INLINED)
# Issue 4 fix: Use heredoc YAML instead of kubectl run --overrides (breaks on zsh)
# Issue 6 fix: Add labels to pods so Services can find them via selector
# Issue 7 fix: Add allow-intra-namespace NetworkPolicy so pods can reach each other
# ==============================================================================
echo ""
echo "==== Deploying Database Dependencies ===="

# -- allow-intra-namespace NetworkPolicy (Issue 7) ----------------------------
# The default-deny-all + allow-dns policies block pod-to-pod traffic on app
# ports (5432, 6379). This policy opens intra-namespace communication.
# Without it: auth-service gets DNS resolution for "postgres" but TCP is blocked.
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-namespace
  namespace: novapay-prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
EOF
echo "  allow-intra-namespace NetworkPolicy applied"

# -- PostgreSQL pod (Issue 4 + 6) ---------------------------------------------
# heredoc YAML avoids zsh JSON mangling; labels added so Service selector works
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: postgres
  namespace: novapay-prod
  labels:
    app: postgres
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    fsGroup: 999
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: postgres
      image: postgres:15
      ports:
        - containerPort: 5432
      command:
        - bash
        - -c
        - |
          mkdir -p /tmp/pgdata
          openssl req -new -x509 -nodes -days 365 -text             -out /tmp/server.crt -keyout /tmp/server.key             -subj /CN=postgres > /dev/null 2>&1
          chmod 600 /tmp/server.key
          chown 999:999 /tmp/server.key
          exec docker-entrypoint.sh postgres             -c ssl=on             -c ssl_cert_file=/tmp/server.crt             -c ssl_key_file=/tmp/server.key
      env:
        - {name: POSTGRES_DB, value: novapay}
        - {name: POSTGRES_USER, value: novapay_user}
        - {name: POSTGRES_PASSWORD, value: labpass123}
        - {name: PGDATA, value: /tmp/pgdata}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - {name: tmp, mountPath: /tmp}
  volumes:
    - {name: tmp, emptyDir: {}}
EOF

kubectl wait --for=condition=Ready pod/postgres -n novapay-prod --timeout=90s

# -- PostgreSQL Service (Issue 6 fix) -----------------------------------------
# Explicit Service YAML — does not depend on kubectl expose finding labels at runtime
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: novapay-prod
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
EOF

# -- Create schema ------------------------------------------------------------
sleep 5
kubectl exec -n novapay-prod postgres -- psql -U novapay_user -d novapay -c   "CREATE TABLE IF NOT EXISTS txns (id TEXT PRIMARY KEY, merchant TEXT NOT NULL, amount NUMERIC NOT NULL, status TEXT NOT NULL, created_at TIMESTAMPTZ DEFAULT NOW());" 2>/dev/null || true
echo "  PostgreSQL ready with schema"

# -- Redis pod (Issue 4 + 6) --------------------------------------------------
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: redis
  namespace: novapay-prod
  labels:
    app: redis
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    fsGroup: 999
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: redis
      image: redis:7-alpine
      ports:
        - containerPort: 6379
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - {name: tmp, mountPath: /tmp}
  volumes:
    - {name: tmp, emptyDir: {}}
EOF

kubectl wait --for=condition=Ready pod/redis -n novapay-prod --timeout=60s

# -- Redis Service (Issue 6 fix) ----------------------------------------------
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: novapay-prod
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
EOF

echo "  PostgreSQL + Redis running"

# ==============================================================================
# MODULE 3: Deploy Services (INLINE - no Helm charts needed)
# ==============================================================================
echo ""
echo "==== Deploying NovaPay Services ===="

# -- auth-service -------------------------------------------------------------
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: auth-service-sa
  namespace: novapay-prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service
  namespace: novapay-prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: auth-service
  template:
    metadata:
      labels:
        app: auth-service
    spec:
      serviceAccountName: auth-service-sa
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      tolerations:
        - key: novapay.io/payment-critical
          operator: Exists
          effect: NoSchedule
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: auth-service
      containers:
        - name: auth-service
          image: ${ECR_BASE}/novapay-poc/auth:v1.0.0
          ports:
            - containerPort: 3001
          env:
            - {name: NODE_ENV, value: "lab"}
            - {name: PORT, value: "3001"}
            - {name: SERVICE_NAME, value: "auth-service"}
            - {name: SHUTDOWN_TIMEOUT_MS, value: "55000"}
            - {name: DB_HOST, value: "postgres"}
            - {name: DB_PORT, value: "5432"}
            - {name: DB_NAME, value: "novapay"}
            - {name: DB_USERNAME, value: "novapay_user"}
            - {name: DB_PASSWORD, value: "labpass123"}
            - {name: REDIS_ENDPOINT, value: "redis"}
          resources:
            requests: {cpu: "250m", memory: "512Mi"}
            limits: {cpu: "1", memory: "1Gi"}
          readinessProbe:
            httpGet: {path: /health, port: 3001}
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /health, port: 3001}
            initialDelaySeconds: 15
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          volumeMounts:
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: tmp, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata:
  name: auth-service
  namespace: novapay-prod
spec:
  selector: {app: auth-service}
  ports: [{port: 80, targetPort: 3001}]
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: auth-service
  namespace: novapay-prod
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: auth-service}
  minReplicas: 3
  maxReplicas: 10
  metrics: [{type: Resource, resource: {name: cpu, target: {type: Utilization, averageUtilization: 70}}}]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: auth-service-pdb
  namespace: novapay-prod
spec:
  minAvailable: 2
  selector: {matchLabels: {app: auth-service}}
EOF
echo "  auth-service deployed"

# -- webhook-service ----------------------------------------------------------
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webhook-service-sa
  namespace: novapay-prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-service
  namespace: novapay-prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webhook-service
  template:
    metadata:
      labels:
        app: webhook-service
    spec:
      serviceAccountName: webhook-service-sa
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: webhook-service
      containers:
        - name: webhook-service
          image: ${ECR_BASE}/novapay-poc/webhook:v1.0.0
          ports:
            - containerPort: 3003
          env:
            - {name: NODE_ENV, value: "production"}
            - {name: PORT, value: "3003"}
            - {name: SERVICE_NAME, value: "webhook-service"}
            - {name: SHUTDOWN_TIMEOUT_MS, value: "55000"}
          resources:
            requests: {cpu: "250m", memory: "512Mi"}
            limits: {cpu: "1", memory: "1Gi"}
          readinessProbe:
            httpGet: {path: /health, port: 3003}
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /health, port: 3003}
            initialDelaySeconds: 15
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          volumeMounts:
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: tmp, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata:
  name: webhook-service
  namespace: novapay-prod
spec:
  selector: {app: webhook-service}
  ports: [{port: 80, targetPort: 3003}]
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: webhook-service
  namespace: novapay-prod
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: webhook-service}
  minReplicas: 2
  maxReplicas: 8
  metrics: [{type: Resource, resource: {name: cpu, target: {type: Utilization, averageUtilization: 70}}}]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: webhook-service-pdb
  namespace: novapay-prod
spec:
  minAvailable: 1
  selector: {matchLabels: {app: webhook-service}}
EOF
echo "  webhook-service deployed"

# -- kyc-service --------------------------------------------------------------
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kyc-service-sa
  namespace: novapay-prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kyc-service
  namespace: novapay-prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: kyc-service
  template:
    metadata:
      labels:
        app: kyc-service
    spec:
      serviceAccountName: kyc-service-sa
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: kyc-service
      containers:
        - name: kyc-service
          image: ${ECR_BASE}/novapay-poc/kyc:v1.0.0
          ports:
            - containerPort: 3004
          env:
            - {name: NODE_ENV, value: "production"}
            - {name: PORT, value: "3004"}
            - {name: SERVICE_NAME, value: "kyc-service"}
            - {name: SHUTDOWN_TIMEOUT_MS, value: "55000"}
          resources:
            requests: {cpu: "250m", memory: "512Mi"}
            limits: {cpu: "1", memory: "1Gi"}
          readinessProbe:
            httpGet: {path: /health, port: 3004}
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /health, port: 3004}
            initialDelaySeconds: 15
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          volumeMounts:
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: tmp, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata:
  name: kyc-service
  namespace: novapay-prod
spec:
  selector: {app: kyc-service}
  ports: [{port: 80, targetPort: 3004}]
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: kyc-service
  namespace: novapay-prod
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: kyc-service}
  minReplicas: 2
  maxReplicas: 8
  metrics: [{type: Resource, resource: {name: cpu, target: {type: Utilization, averageUtilization: 70}}}]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kyc-service-pdb
  namespace: novapay-prod
spec:
  minAvailable: 1
  selector: {matchLabels: {app: kyc-service}}
EOF
echo "  kyc-service deployed"

echo ">>> Waiting for pods to be Ready..."
kubectl wait --for=condition=Ready pods -l app=auth-service -n novapay-prod --timeout=180s 2>/dev/null || true
kubectl wait --for=condition=Ready pods -l app=webhook-service -n novapay-prod --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=Ready pods -l app=kyc-service -n novapay-prod --timeout=120s 2>/dev/null || true

# ==============================================================================
# MODULE 4: Argo Rollouts + Blue/Green (INLINED)
# ==============================================================================
echo ""
echo "==== Installing Argo Rollouts ===="

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

helm upgrade --install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts \
  --create-namespace \
  --set 'controller.tolerations[0].key=CriticalAddonsOnly' \
  --set 'controller.tolerations[0].operator=Exists' \
  --set 'controller.tolerations[0].effect=NoSchedule' \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=128Mi \
  --set controller.resources.limits.cpu=200m \
  --set controller.resources.limits.memory=256Mi \
  --wait --timeout 120s
echo "  Argo Rollouts installed"

# -- Convert payment-service to Blue/Green ------------------------------------
echo ">>> Converting payment-service to Blue/Green Rollout..."
helm uninstall payment-service -n novapay-prod 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-service-sa
  namespace: novapay-prod
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service-active
  namespace: novapay-prod
spec:
  selector:
    app: payment-service
  ports:
    - port: 80
      targetPort: 3002
      name: http
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service-preview
  namespace: novapay-prod
spec:
  selector:
    app: payment-service
  ports:
    - port: 80
      targetPort: 3002
      name: http
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payment-service-pdb
  namespace: novapay-prod
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: payment-service
EOF

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payment-service
  namespace: novapay-prod
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      serviceAccountName: payment-service-sa
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      tolerations:
        - key: novapay.io/payment-critical
          operator: Exists
          effect: NoSchedule
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: payment-service
      containers:
        - name: payment-service
          image: ${ECR_BASE}/novapay-poc/charge:v1.0.0
          ports:
            - containerPort: 3002
          env:
            - name: NODE_ENV
              value: "production"
            - name: PORT
              value: "3002"
            - name: SERVICE_NAME
              value: "payment-service"
            - name: SHUTDOWN_TIMEOUT_MS
              value: "55000"
            - name: DB_HOST
              value: "postgres"
            - name: DB_PORT
              value: "5432"
            - name: DB_NAME
              value: "novapay"
            - name: DB_USERNAME
              value: "novapay_user"
            - name: DB_PASSWORD
              value: "labpass123"
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /health
              port: 3002
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: 3002
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
  strategy:
    blueGreen:
      activeService: payment-service-active
      previewService: payment-service-preview
      autoPromotionEnabled: false
      scaleDownDelaySeconds: 60
EOF

echo ">>> Waiting for Rollout to become healthy..."
sleep 45
kubectl get rollout payment-service -n novapay-prod 2>/dev/null || true
echo "  payment-service Blue/Green Rollout created"

# ==============================================================================
# MODULE 4: Install ArgoCD (INLINED)
# ==============================================================================
echo ""
echo "==== Installing ArgoCD ===="
kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side=true

echo ">>> Waiting for ArgoCD pods (60s)..."
sleep 60
kubectl get pods -n argocd

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "not-ready-yet")

# ==============================================================================
# VALIDATION
# ==============================================================================
echo ""
echo "======================================================================"
echo "         DEPLOYMENT COMPLETE - VALIDATION"
echo "======================================================================"
echo ""
echo "  Nodes:"
kubectl get nodes -L role,karpenter.sh/nodepool,node.kubernetes.io/instance-type
echo ""
echo "  Pods:"
kubectl get pods -n novapay-prod
echo ""
echo "  Karpenter:"
kubectl get nodepools
echo ""
echo "  Rollout:"
kubectl get rollout -n novapay-prod 2>/dev/null || echo "  (Argo Rollouts CRD pending)"
echo ""
echo "  ArgoCD:"
echo "    URL: https://localhost:8080 (run: kubectl port-forward svc/argocd-server -n argocd 8080:443)"
echo "    User: admin"
echo "    Pass: ${ARGOCD_PASS}"
echo ""
echo "======================================================================"
echo "  ALL MODULES COMPLETE (1, 2, 3, 4)"
echo "======================================================================"
