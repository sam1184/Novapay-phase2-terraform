#!/bin/bash
# ==============================================================================
# NovaPay - Generate Application Source Code
# Creates all service source files in a temporary directory for Docker builds.
# Called by post-apply.sh. Fully self-contained - no external file dependencies.
#
# Output: Creates services/ directory at the specified location with:
#   services/auth/     (Dockerfile, server.js, package.json)
#   services/charge/   (Dockerfile, server.js, package.json)
#   services/webhook/  (Dockerfile, server.js, package.json)
#   services/kyc/      (Dockerfile, server.js, package.json)
#
# Usage: ./generate-sources.sh /path/to/output
# ==============================================================================

set -euo pipefail

OUTPUT_DIR="${1:-.}"

echo ">>> Generating NovaPay service sources in ${OUTPUT_DIR}/services/"

mkdir -p "${OUTPUT_DIR}/services/auth"
mkdir -p "${OUTPUT_DIR}/services/charge"
mkdir -p "${OUTPUT_DIR}/services/webhook"
mkdir -p "${OUTPUT_DIR}/services/kyc"

# -- Shared Dockerfile (same for all services, parameterized by PORT) ----------
generate_dockerfile() {
  local SVC_DIR="$1"
  local PORT="$2"
  cat > "${SVC_DIR}/Dockerfile" << 'DOCKERFILE'
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --ignore-scripts

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
RUN apk add --no-cache curl
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node server.js ./
COPY --chown=node:node package.json ./
USER node
EXPOSE REPLACE_PORT
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -sf http://localhost:REPLACE_PORT/health || exit 1
CMD ["node", "server.js"]
DOCKERFILE
  # Replace port placeholder
  sed -i.bak "s/REPLACE_PORT/${PORT}/g" "${SVC_DIR}/Dockerfile" && rm -f "${SVC_DIR}/Dockerfile.bak"
}

generate_dockerfile "${OUTPUT_DIR}/services/auth"    "3001"
generate_dockerfile "${OUTPUT_DIR}/services/charge"  "3002"
generate_dockerfile "${OUTPUT_DIR}/services/webhook" "3003"
generate_dockerfile "${OUTPUT_DIR}/services/kyc"     "3004"

# -- Package.json files --------------------------------------------------------
cat > "${OUTPUT_DIR}/services/auth/package.json" << 'EOF'
{"name":"novapay-auth","version":"1.0.0","main":"server.js","dependencies":{"body-parser":"^1.20.2","express":"^4.18.2","ioredis":"^5.3.2","pg":"^8.11.3"}}
EOF

cat > "${OUTPUT_DIR}/services/charge/package.json" << 'EOF'
{"name":"novapay-charge","version":"1.0.0","main":"server.js","dependencies":{"@aws-sdk/client-sqs":"^3.550.0","body-parser":"^1.20.2","express":"^4.18.2","pg":"^8.11.3"}}
EOF

cat > "${OUTPUT_DIR}/services/webhook/package.json" << 'EOF'
{"name":"novapay-webhook","version":"1.0.0","main":"server.js","dependencies":{"@aws-sdk/client-sqs":"^3.550.0","body-parser":"^1.20.2","express":"^4.18.2"}}
EOF

cat > "${OUTPUT_DIR}/services/kyc/package.json" << 'EOF'
{"name":"novapay-kyc","version":"1.0.0","main":"server.js","dependencies":{"body-parser":"^1.20.2","express":"^4.18.2"}}
EOF

# -- Buildspec for CodeBuild ---------------------------------------------------
cat > "${OUTPUT_DIR}/buildspec.yml" << 'EOF'
version: 0.2
env:
  variables:
    AWS_REGION: "us-east-1"
    ECR_PREFIX: "novapay-poc"
    IMAGE_TAG: "latest"
phases:
  pre_build:
    commands:
      - ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
      - ECR_BASE="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
      - aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_BASE"
  build:
    commands:
      - |
        for svc in auth charge webhook kyc; do
          REPO="$ECR_BASE/$ECR_PREFIX/$svc"
          docker build --target runner --platform linux/amd64 -t "$REPO:$IMAGE_TAG" "services/$svc"
          docker push "$REPO:$IMAGE_TAG"
        done
EOF

echo "  Source files generated"

# Generate server.js files
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "${SCRIPT_DIR}/generate-server-code.sh" "${OUTPUT_DIR}"
