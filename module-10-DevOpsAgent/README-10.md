# NovaPay Module 10 — AWS DevOps Agent Lab (Standalone)

An end-to-end lab that validates the full capability set of AWS DevOps Agent (the managed AWS service) against a real EKS platform running NovaPay's `payment-service` and `webhook-service`, with ArgoCD as the delivery engine.

AWS DevOps Agent is an autonomous, frontier AI agent (GA March 2026) that acts as an always-on SRE: it investigates incidents, performs root-cause analysis, proposes mitigations, recommends reliability improvements, and (preview) reviews code changes before production. This lab exercises every one of those capabilities.

## What's included

| File | Purpose |
|---|---|
| `main.tf` | Base EKS cluster + the AWS-side prerequisites the agent consumes (control-plane audit logging, Container Insights, IAM Agent Space role, CloudWatch alarm, SNS + EventBridge trigger, ECR repos) |
| `post-cluster.sh` | Installs ArgoCD + LB controller, deploys NovaPay services, verifies observability, seeds baseline traffic |
| `module-10-demo.sh` | The interactive lab: 7 parts, ~24 live checks, manufactures a real incident |
| `devops-agent-guide.html` | Full teaching material (open in a browser) |
| `teardown.sh` | Safe cleanup (removes ALBs/log groups, then `terraform destroy`) |
| `agent-standards/` | Generated plain-English release-readiness standards (Part G) |

## How "executable" works for a managed service

The DevOps Agent itself runs in the AWS console / via its API. This lab is designed so everything the agent depends on is produced by real components and validated by script, and the console steps are reduced to a short checklist.



- `payment-service` and `auth-service` are real HTTP applications. auth issues v1 tokens; payment validates them. The incident is created by changing payment to expect v2 — so every real request fails to parse the real v1 token and returns a real HTTP 502 with a real `token` parse error log line.
- A metrics sidecar counts the actual request/5xx outcomes from the app's access log and publishes them with `cloudwatch:PutMetricData`. The numbers are measured, never fabricated. That real metric is what fires the CloudWatch alarm.
- The `traffic-generator` / `module-10-demo.sh` injects nothing. It flips the deploy, runs a live `login → charge` probe to prove the real 200 → 502 → 200 transition, then reads the resulting real CloudWatch metrics, real CloudWatch Logs, real deploy annotation, and real EKS audit logs — each verified with a PASS/FAIL check.

## Reusable — built to run

- Every step is idempotent (`kubectl apply`, `create --dry-run`, `set env`, `annotate --overwrite`). No resource-name collisions across runs.
- A full demo run ends with the service healthy (Part D rolls back to v1), so the next run starts from a clean baseline. Re-run `module-10-demo.sh` as often as you like without re-applying Terraform.
- `terraform apply` / `post-cluster.sh` are also idempotent if you want to rebuild.

## Prerequisites

- AWS account with access to `us-east-1` (the agent's home Region) and the AWS DevOps Agent console (GA; 2-month free trial for new customers)
- Terraform ≥ 1.5, `kubectl`, `helm`, AWS CLI, `python3` (optional, for richer logs)
- A GitHub/GitLab repo to connect for Part G (release review) — optional

## Quick start

```bash
cd devops-agent-lab
terraform init
terraform apply          # ~14 min  (EKS + services + agent prerequisites)
bash post-cluster.sh      # ~6 min   (ArgoCD + NovaPay + observability)
bash module-10-demo.sh    # the capability-validation lab (add --auto for CI)
bash teardown.sh           # cleanup
```

After `terraform apply`, note the printed `devops_agent_space_role_arn` — you paste it into the console when you create the Agent Space.

## The 7 capabilities validated

| Part | DevOps Agent capability | What the lab does |
|---|---|---|
| A | Agent Space + topology | Validates the read-only IAM role + discoverable EKS/observability/ArgoCD topology |
| B | Autonomous incident response | Manufactures the real "March incident" and drives the alarm trigger |
| C | Root-cause correlation | Verifies metrics, logs, deploy-history, and audit/trace sources are real & queryable |
| D | Mitigation + recovery | Rolls payment-service back, confirms the alarm returns to OK |
| E | EKS-native diagnosis | Reproduces CrashLoopBackOff + a ConfigMap deletion in the audit log |
| F | Proactive recommendations | Verifies the evidence the agent uses (missing alarm, risky strategy, no timeout) |
| G | Release readiness review | Authors plain-English standards; gates a risky PR (BLOCK) before production |

**Expected result:** `PASSED: 24 FAILED: 0`

## How this builds on the other modules

- **Modules 3–4 (Blue/Green):** the mitigation + the recommendation to replace RollingUpdate with Argo Rollouts.
- **Module 6 (Observability):** the metrics/logs/traces the agent correlates.
- **Module 9 (Networking):** the real pod-IP topology that makes the agent's knowledge graph precise.
- **Module 7 (Checkov):** pairs with Part G for full shift-left release safety.

## Cost & safety

~$0.40/hour while running. Always `bash teardown.sh` when done. The agent's introspection role is read-only — it recommends; changes still flow through your reviewed ArgoCD/Blue-Green pipeline. Delete the Agent Space in the console separately (Terraform does not manage it).
