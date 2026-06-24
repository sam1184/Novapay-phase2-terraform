#!/usr/bin/env bash
# =============================================================================
#  aws-nuke-region.sh  —  Nuclear cleanup of ALL resources in a single region
#  Author : AI Arch Bootcamp (aiarchbootcamp.com)
#  Usage  : bash aws-nuke-region.sh [--region ap-south-1] [--dry-run]
#
#  ⚠️  DANGER: This script DELETES resources. It cannot be undone.
#      Always review the dry-run output before running live.
# =============================================================================
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
DRY_RUN=false
SKIP_CONFIRM=false
LOG_FILE="aws-nuke-$(date +%Y%m%d-%H%M%S).log"

# ─── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --region)    REGION="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --yes)       SKIP_CONFIRM=true; shift ;;
    --log)       LOG_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--region REGION] [--dry-run] [--yes] [--log FILE]"
      echo "  --region   AWS region (default: \$AWS_DEFAULT_REGION or us-east-1)"
      echo "  --dry-run  List resources without deleting"
      echo "  --yes      Skip confirmation prompts (DANGEROUS)"
      echo "  --log      Log file path (default: aws-nuke-<timestamp>.log)"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "$*" | tee -a "$LOG_FILE"; }
info() { log "${CYAN}[INFO]${NC}  $*"; }
warn() { log "${YELLOW}[WARN]${NC}  $*"; }
ok()   { log "${GREEN}[ OK ]${NC}  $*"; }
err()  { log "${RED}[ERR ]${NC}  $*"; }
sep()  { log "${DIM}──────────────────────────────────────────────────────────${NC}"; }

aws_cmd() {
  # Wrapper: print what would run in dry-run; execute otherwise
  local svc="$1"; shift
  local full_cmd="aws $svc $* --region $REGION --output text 2>/dev/null"
  if $DRY_RUN; then
    echo "  ${DIM}[DRY-RUN]${NC} aws $svc $* --region $REGION" | tee -a "$LOG_FILE"
    return 0
  fi
  eval "$full_cmd" 2>>"$LOG_FILE" || true
}

delete_or_dryrun() {
  # $1 = resource label, $2+ = aws cli command tokens (no --region)
  local label="$1"; shift
  if $DRY_RUN; then
    log "  ${DIM}[DRY-RUN]${NC} Would delete: ${YELLOW}$label${NC}"
  else
    warn "  Deleting: $label"
    aws "$@" --region "$REGION" --output text 2>>"$LOG_FILE" || \
      err "  Failed to delete $label (see $LOG_FILE)"
  fi
}

confirm() {
  local prompt="$1"
  if $SKIP_CONFIRM; then return 0; fi
  read -rp "$(echo -e "${YELLOW}${prompt} [yes/NO]: ${NC}")" ans
  [[ "$ans" == "yes" ]]
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
clear
log ""
log "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
log "${RED}${BOLD}║           AWS REGION NUCLEAR CLEANUP — USE WITH CARE         ║${NC}"
log "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
log ""

# Verify AWS CLI is available
if ! command -v aws &>/dev/null; then
  err "AWS CLI not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
  exit 1
fi

# Verify credentials
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
if [[ -z "$ACCOUNT_ID" ]]; then
  err "AWS credentials not configured or invalid. Run: aws configure"
  exit 1
fi

CALLER=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)

log "${BOLD}  Account ID : ${RED}$ACCOUNT_ID${NC}"
log "${BOLD}  Caller ARN : ${CYAN}$CALLER${NC}"
log "${BOLD}  Region     : ${YELLOW}$REGION${NC}"
log "${BOLD}  Mode       : $(if $DRY_RUN; then echo "${GREEN}DRY-RUN (safe)${NC}"; else echo "${RED}LIVE — resources WILL be deleted${NC}"; fi)"
log "${BOLD}  Log file   : $LOG_FILE${NC}"
log ""

if ! $DRY_RUN; then
  log "${RED}${BOLD}  ⚠️  WARNING: This will PERMANENTLY DELETE resources in $REGION${NC}"
  log "${RED}  There is NO undo. Billing stops, but data is gone forever.${NC}"
  log ""
  if ! confirm "Type 'yes' to confirm you understand and want to proceed"; then
    log "Aborted."; exit 0
  fi
  log ""
  log "${RED}  Last chance — are you absolutely sure?${NC}"
  if ! confirm "Type 'yes' again to proceed with deletion in $REGION"; then
    log "Aborted."; exit 0
  fi
fi

log ""
info "Starting cleanup — $(date)"
sep

# =============================================================================
# 1. ECS (Clusters, Services, Tasks)
# =============================================================================
info "§1  ECS — Clusters / Services / Tasks"

CLUSTERS=$(aws ecs list-clusters --region "$REGION" --query 'clusterArns[]' --output text 2>/dev/null || true)
for cluster in $CLUSTERS; do
  cluster_name=$(basename "$cluster")
  info "  Cluster: $cluster_name"

  # Stop all running tasks
  TASKS=$(aws ecs list-tasks --cluster "$cluster" --region "$REGION" --query 'taskArns[]' --output text 2>/dev/null || true)
  for task in $TASKS; do
    delete_or_dryrun "ECS Task $task" ecs stop-task --cluster "$cluster" --task "$task"
  done

  # Delete all services
  SERVICES=$(aws ecs list-services --cluster "$cluster" --region "$REGION" --query 'serviceArns[]' --output text 2>/dev/null || true)
  for svc in $SERVICES; do
    # Scale to 0 first
    if ! $DRY_RUN; then
      aws ecs update-service --cluster "$cluster" --service "$svc" --desired-count 0 --region "$REGION" --output text &>/dev/null || true
    fi
    delete_or_dryrun "ECS Service $svc" ecs delete-service --cluster "$cluster" --service "$svc" --force
  done

  delete_or_dryrun "ECS Cluster $cluster_name" ecs delete-cluster --cluster "$cluster"
done
ok "ECS done"; sep

# =============================================================================
# 2. EC2 — Instances
# =============================================================================
info "§2  EC2 — Instances"
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text 2>/dev/null || true)

if [[ -n "$INSTANCE_IDS" ]]; then
  log "  Found: $INSTANCE_IDS"
  if ! $DRY_RUN; then
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" --output text 2>>"$LOG_FILE" || true
    info "  Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION" 2>>"$LOG_FILE" || true
  else
    log "  ${DIM}[DRY-RUN]${NC} Would terminate: $INSTANCE_IDS"
  fi
else
  ok "  No instances found"
fi
ok "EC2 Instances done"; sep

# =============================================================================
# 3. EC2 — Load Balancers (ALB / NLB / CLB)
# =============================================================================
info "§3  Elastic Load Balancers"

LB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)
for lb in $LB_ARNS; do
  delete_or_dryrun "ELBv2 $lb" elbv2 delete-load-balancer --load-balancer-arn "$lb"
done

# Classic ELBs
CLB_NAMES=$(aws elb describe-load-balancers --region "$REGION" --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null || true)
for clb in $CLB_NAMES; do
  delete_or_dryrun "Classic ELB $clb" elb delete-load-balancer --load-balancer-name "$clb"
done

# Target groups
TG_ARNS=$(aws elbv2 describe-target-groups --region "$REGION" --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || true)
for tg in $TG_ARNS; do
  delete_or_dryrun "Target Group $tg" elbv2 delete-target-group --target-group-arn "$tg"
done
ok "Load Balancers done"; sep

# =============================================================================
# 4. RDS — Instances & Clusters
# =============================================================================
info "§4  RDS — DB Instances & Clusters"

RDS_INSTANCES=$(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null || true)
for db in $RDS_INSTANCES; do
  delete_or_dryrun "RDS Instance $db" rds delete-db-instance \
    --db-instance-identifier "$db" \
    --skip-final-snapshot \
    --delete-automated-backups
done

RDS_CLUSTERS=$(aws rds describe-db-clusters --region "$REGION" --query 'DBClusters[].DBClusterIdentifier' --output text 2>/dev/null || true)
for cluster in $RDS_CLUSTERS; do
  delete_or_dryrun "RDS Cluster $cluster" rds delete-db-cluster \
    --db-cluster-identifier "$cluster" \
    --skip-final-snapshot
done
ok "RDS done"; sep

# =============================================================================
# 5. ElastiCache — Clusters & Replication Groups
# =============================================================================
info "§5  ElastiCache"

CACHE_CLUSTERS=$(aws elasticache describe-cache-clusters --region "$REGION" --query 'CacheClusters[?CacheClusterStatus!=`deleted`].CacheClusterId' --output text 2>/dev/null || true)
for cc in $CACHE_CLUSTERS; do
  delete_or_dryrun "ElastiCache Cluster $cc" elasticache delete-cache-cluster --cache-cluster-id "$cc"
done

REP_GROUPS=$(aws elasticache describe-replication-groups --region "$REGION" --query 'ReplicationGroups[].ReplicationGroupId' --output text 2>/dev/null || true)
for rg in $REP_GROUPS; do
  delete_or_dryrun "ElastiCache RepGroup $rg" elasticache delete-replication-group --replication-group-id "$rg"
done
ok "ElastiCache done"; sep

# =============================================================================
# 6. Lambda — Functions
# =============================================================================
info "§6  Lambda Functions"
FUNCTIONS=$(aws lambda list-functions --region "$REGION" --query 'Functions[].FunctionName' --output text 2>/dev/null || true)
for fn in $FUNCTIONS; do
  delete_or_dryrun "Lambda $fn" lambda delete-function --function-name "$fn"
done
ok "Lambda done"; sep

# =============================================================================
# 7. SQS — Queues
# =============================================================================
info "§7  SQS Queues"
QUEUES=$(aws sqs list-queues --region "$REGION" --query 'QueueUrls[]' --output text 2>/dev/null || true)
for q in $QUEUES; do
  delete_or_dryrun "SQS $q" sqs delete-queue --queue-url "$q"
done
ok "SQS done"; sep

# =============================================================================
# 8. SNS — Topics
# =============================================================================
info "§8  SNS Topics"
TOPICS=$(aws sns list-topics --region "$REGION" --query 'Topics[].TopicArn' --output text 2>/dev/null || true)
for t in $TOPICS; do
  delete_or_dryrun "SNS Topic $t" sns delete-topic --topic-arn "$t"
done
ok "SNS done"; sep

# =============================================================================
# 9. S3 — Buckets in region
# =============================================================================
info "§9  S3 Buckets (region-filtered)"
ALL_BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || true)
for bucket in $ALL_BUCKETS; do
  BLOC=$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text 2>/dev/null || true)
  # AWS returns "None" for us-east-1
  [[ "$BLOC" == "None" ]] && BLOC="us-east-1"
  if [[ "$BLOC" != "$REGION" ]]; then continue; fi

  if $DRY_RUN; then
    log "  ${DIM}[DRY-RUN]${NC} Would empty + delete bucket: ${YELLOW}s3://$bucket${NC}"
  else
    warn "  Emptying s3://$bucket ..."
    aws s3 rm "s3://$bucket" --recursive --region "$REGION" 2>>"$LOG_FILE" || true
    # Delete versioned objects
    aws s3api delete-objects --bucket "$bucket" \
      --delete "$(aws s3api list-object-versions --bucket "$bucket" \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null)" \
      --region "$REGION" 2>>"$LOG_FILE" || true
    # Delete markers
    aws s3api delete-objects --bucket "$bucket" \
      --delete "$(aws s3api list-object-versions --bucket "$bucket" \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null)" \
      --region "$REGION" 2>>"$LOG_FILE" || true
    aws s3api delete-bucket --bucket "$bucket" --region "$REGION" 2>>"$LOG_FILE" || \
      err "  Could not delete $bucket"
  fi
done
ok "S3 done"; sep

# =============================================================================
# 10. ECR — Repositories
# =============================================================================
info "§10 ECR Repositories"
REPOS=$(aws ecr describe-repositories --region "$REGION" --query 'repositories[].repositoryName' --output text 2>/dev/null || true)
for repo in $REPOS; do
  delete_or_dryrun "ECR repo $repo" ecr delete-repository --repository-name "$repo" --force
done
ok "ECR done"; sep

# =============================================================================
# 11. Secrets Manager
# =============================================================================
info "§11 Secrets Manager"
SECRETS=$(aws secretsmanager list-secrets --region "$REGION" --query 'SecretList[].ARN' --output text 2>/dev/null || true)
for secret in $SECRETS; do
  delete_or_dryrun "Secret $secret" secretsmanager delete-secret \
    --secret-id "$secret" \
    --force-delete-without-recovery
done
ok "Secrets Manager done"; sep

# =============================================================================
# 12. CloudWatch — Log Groups & Alarms
# =============================================================================
info "§12 CloudWatch Log Groups"
LOG_GROUPS=$(aws logs describe-log-groups --region "$REGION" --query 'logGroups[].logGroupName' --output text 2>/dev/null || true)
for lg in $LOG_GROUPS; do
  delete_or_dryrun "Log Group $lg" logs delete-log-group --log-group-name "$lg"
done

info "§12 CloudWatch Alarms"
ALARMS=$(aws cloudwatch describe-alarms --region "$REGION" --query 'MetricAlarms[].AlarmName' --output text 2>/dev/null || true)
if [[ -n "$ALARMS" ]]; then
  if $DRY_RUN; then
    log "  ${DIM}[DRY-RUN]${NC} Would delete alarms: $ALARMS"
  else
    aws cloudwatch delete-alarms --alarm-names $ALARMS --region "$REGION" 2>>"$LOG_FILE" || true
  fi
fi
ok "CloudWatch done"; sep

# =============================================================================
# 13. NAT Gateways
# =============================================================================
info "§13 NAT Gateways"
NAT_GWS=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=state,Values=pending,available" \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)
for nat in $NAT_GWS; do
  delete_or_dryrun "NAT Gateway $nat" ec2 delete-nat-gateway --nat-gateway-id "$nat"
done
ok "NAT Gateways done"; sep

# =============================================================================
# 14. Elastic IPs
# =============================================================================
info "§14 Elastic IPs"
EIPS=$(aws ec2 describe-addresses --region "$REGION" --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)
for eip in $EIPS; do
  delete_or_dryrun "Elastic IP $eip" ec2 release-address --allocation-id "$eip"
done
ok "Elastic IPs done"; sep

# =============================================================================
# 15. Security Groups (non-default)
# =============================================================================
info "§15 Security Groups (non-default)"
SGS=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=!default" \
  --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)
for sg in $SGS; do
  delete_or_dryrun "Security Group $sg" ec2 delete-security-group --group-id "$sg"
done
ok "Security Groups done"; sep

# =============================================================================
# 16. VPCs (non-default) — subnets, IGWs, route tables, peering
# =============================================================================
info "§16 VPCs (non-default)"
VPCS=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=false" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)

for vpc in $VPCS; do
  info "  VPC: $vpc"

  # Subnets
  SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)
  for subnet in $SUBNETS; do
    delete_or_dryrun "Subnet $subnet" ec2 delete-subnet --subnet-id "$subnet"
  done

  # Internet Gateways
  IGWS=$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$vpc" \
    --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || true)
  for igw in $IGWS; do
    if ! $DRY_RUN; then
      aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$REGION" 2>>"$LOG_FILE" || true
    fi
    delete_or_dryrun "IGW $igw" ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done

  # Non-main route tables
  RTS=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
    --output text 2>/dev/null || true)
  for rt in $RTS; do
    delete_or_dryrun "Route Table $rt" ec2 delete-route-table --route-table-id "$rt"
  done

  # VPC Peering connections
  PEERS=$(aws ec2 describe-vpc-peering-connections --region "$REGION" \
    --filters "Name=requester-vpc-info.vpc-id,Values=$vpc" \
    --query 'VpcPeeringConnections[].VpcPeeringConnectionId' --output text 2>/dev/null || true)
  for peer in $PEERS; do
    delete_or_dryrun "VPC Peering $peer" ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$peer"
  done

  delete_or_dryrun "VPC $vpc" ec2 delete-vpc --vpc-id "$vpc"
done
ok "VPCs done"; sep

# =============================================================================
# 17. IAM Roles, Policies, Users (region-scoped: skip global if not needed)
# =============================================================================
info "§17 IAM — Non-AWS-managed Roles (global — skipped by default)"
warn "  IAM is global. Skipping to avoid breaking cross-region services."
warn "  To clean IAM, run manually with care."
ok "IAM skipped"; sep

# =============================================================================
# 18. EKS Clusters
# =============================================================================
info "§18 EKS Clusters"
EKS_CLUSTERS=$(aws eks list-clusters --region "$REGION" --query 'clusters[]' --output text 2>/dev/null || true)
for eks in $EKS_CLUSTERS; do
  # Delete node groups first
  NGs=$(aws eks list-nodegroups --cluster-name "$eks" --region "$REGION" --query 'nodegroups[]' --output text 2>/dev/null || true)
  for ng in $NGs; do
    delete_or_dryrun "EKS NodeGroup $ng" eks delete-nodegroup --cluster-name "$eks" --nodegroup-name "$ng"
    if ! $DRY_RUN; then
      aws eks wait nodegroup-deleted --cluster-name "$eks" --nodegroup-name "$ng" --region "$REGION" 2>>"$LOG_FILE" || true
    fi
  done
  delete_or_dryrun "EKS Cluster $eks" eks delete-cluster --name "$eks"
done
ok "EKS done"; sep

# =============================================================================
# 19. Bedrock — Knowledge Bases & Agents (if region supports it)
# =============================================================================
info "§19 Bedrock Agents & Knowledge Bases"
AGENTS=$(aws bedrock-agent list-agents --region "$REGION" --query 'agentSummaries[].agentId' --output text 2>/dev/null || true)
for agent in $AGENTS; do
  delete_or_dryrun "Bedrock Agent $agent" bedrock-agent delete-agent --agent-id "$agent"
done

KBS=$(aws bedrock-agent list-knowledge-bases --region "$REGION" --query 'knowledgeBaseSummaries[].knowledgeBaseId' --output text 2>/dev/null || true)
for kb in $KBS; do
  delete_or_dryrun "Bedrock KB $kb" bedrock-agent delete-knowledge-base --knowledge-base-id "$kb"
done
ok "Bedrock done"; sep

# =============================================================================
# 20. DynamoDB Tables
# =============================================================================
info "§20 DynamoDB Tables"
TABLES=$(aws dynamodb list-tables --region "$REGION" --query 'TableNames[]' --output text 2>/dev/null || true)
for table in $TABLES; do
  delete_or_dryrun "DynamoDB Table $table" dynamodb delete-table --table-name "$table"
done
ok "DynamoDB done"; sep

# =============================================================================
# Summary
# =============================================================================
sep
log ""
log "${BOLD}$(if $DRY_RUN; then echo "${GREEN}DRY-RUN COMPLETE"; else echo "${RED}CLEANUP COMPLETE"; fi)${NC}"
log "  Region  : $REGION"
log "  Account : $ACCOUNT_ID"
log "  Mode    : $(if $DRY_RUN; then echo 'Dry-run — nothing deleted'; else echo 'Live — resources deleted'; fi)"
log "  Log     : $LOG_FILE"
log ""
if ! $DRY_RUN; then
  warn "Some resources (RDS, EKS node groups, NAT GWs) take minutes to delete."
  warn "Re-run in ~10 minutes to catch anything that was still shutting down."
fi
log ""
