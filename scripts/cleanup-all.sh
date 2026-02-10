#!/bin/bash
###############################################################################
# Denodo Keycloak POC - Complete Cleanup Script
#
# Deletes ALL POC resources in reverse dependency order.
#
# ⚠ WARNING: This script permanently deletes all resources!
#
# Usage: ./scripts/cleanup-all.sh [--force]
#
# Date: February 2026
# Author: Jaafar Benabderrazak
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENT_INFO="$PROJECT_DIR/deployment-info.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_phase() { echo -e "\n${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"; echo -e "${MAGENTA}║ $1${NC}"; echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}\n"; }
log_step() { echo -e "${CYAN}▶${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }

###############################################################################
# PHASE 0: Read deployment info & confirm
###############################################################################

log_phase "DENODO KEYCLOAK POC - COMPLETE CLEANUP"

if [ ! -f "$DEPLOYMENT_INFO" ]; then
    log_warn "deployment-info.json not found. Using defaults."
    REGION="eu-west-3"
    PROJECT_NAME="denodo-poc"
else
    REGION=$(jq -r '.region' "$DEPLOYMENT_INFO")
    ACCOUNT_ID=$(jq -r '.accountId' "$DEPLOYMENT_INFO")
    PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO")
    VPC_ID=$(jq -r '.vpcId' "$DEPLOYMENT_INFO")
fi

FORCE_MODE="${1:-}"

if [ "$FORCE_MODE" != "--force" ]; then
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠  WARNING: This will DELETE ALL POC resources!         ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  Region:  $REGION                                    ║${NC}"
    echo -e "${RED}║  Project: $PROJECT_NAME                              ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "Type 'DELETE' to confirm: " CONFIRM
    if [ "$CONFIRM" != "DELETE" ]; then
        log_info "Cleanup cancelled."
        exit 0
    fi
fi

echo ""

###############################################################################
# PHASE 1: Delete ECS Services & Cluster
###############################################################################

log_phase "PHASE 1: DELETING ECS RESOURCES"

ECS_CLUSTER="denodo-keycloak-cluster"

log_step "Stopping ECS services..."
for SERVICE in keycloak-provider keycloak-consumer; do
    aws ecs update-service \
        --cluster "$ECS_CLUSTER" \
        --service "$SERVICE" \
        --desired-count 0 \
        --region "$REGION" > /dev/null 2>&1 && log_success "Scaled down $SERVICE" || log_warn "$SERVICE not found"

    aws ecs delete-service \
        --cluster "$ECS_CLUSTER" \
        --service "$SERVICE" \
        --force \
        --region "$REGION" > /dev/null 2>&1 && log_success "Deleted $SERVICE" || log_warn "$SERVICE not found"
done

log_step "Deregistering task definitions..."
for FAMILY in keycloak-provider keycloak-consumer; do
    TASK_DEFS=$(aws ecs list-task-definitions \
        --family-prefix "$FAMILY" \
        --region "$REGION" \
        --query 'taskDefinitionArns[]' --output text 2>/dev/null)
    for TD in $TASK_DEFS; do
        aws ecs deregister-task-definition --task-definition "$TD" --region "$REGION" > /dev/null 2>&1
        log_success "Deregistered $TD"
    done
done

log_step "Deleting ECS cluster..."
aws ecs delete-cluster --cluster "$ECS_CLUSTER" --region "$REGION" > /dev/null 2>&1 \
    && log_success "Deleted cluster $ECS_CLUSTER" || log_warn "Cluster not found"

###############################################################################
# PHASE 2: Delete ALB & Target Groups
###############################################################################

log_phase "PHASE 2: DELETING ALB RESOURCES"

ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names keycloak-alb \
    --region "$REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")

if [ ! -z "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
    # Delete listeners first
    LISTENERS=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$ALB_ARN" \
        --region "$REGION" \
        --query 'Listeners[].ListenerArn' --output text 2>/dev/null)
    for LISTENER in $LISTENERS; do
        aws elbv2 delete-listener --listener-arn "$LISTENER" --region "$REGION" > /dev/null 2>&1
        log_success "Deleted listener"
    done

    # Delete ALB
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION" > /dev/null 2>&1
    log_success "Deleted ALB keycloak-alb"

    # Wait for ALB to be fully deleted before removing target groups
    log_info "Waiting for ALB deletion to complete..."
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" --region "$REGION" 2>/dev/null || sleep 30
else
    log_warn "ALB keycloak-alb not found"
fi

# Delete target groups
for TG_NAME in keycloak-provider-tg keycloak-consumer-tg; do
    TG_ARN=$(aws elbv2 describe-target-groups \
        --names "$TG_NAME" \
        --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
    if [ ! -z "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
        aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION" > /dev/null 2>&1
        log_success "Deleted target group $TG_NAME"
    fi
done

###############################################################################
# PHASE 3: Delete Lambda & API Gateway
###############################################################################

log_phase "PHASE 3: DELETING LAMBDA & API GATEWAY"

LAMBDA_NAME="denodo-permissions-api"
API_NAME="denodo-auth-api"

# Delete Lambda
aws lambda delete-function \
    --function-name "$LAMBDA_NAME" \
    --region "$REGION" > /dev/null 2>&1 \
    && log_success "Deleted Lambda $LAMBDA_NAME" || log_warn "Lambda not found"

# Delete API Gateway
API_ID=$(aws apigateway get-rest-apis \
    --region "$REGION" \
    --query "items[?name=='${API_NAME}'].id" --output text 2>/dev/null)
if [ ! -z "$API_ID" ] && [ "$API_ID" != "None" ]; then
    # Delete usage plans first
    USAGE_PLANS=$(aws apigateway get-usage-plans \
        --region "$REGION" \
        --query "items[?name=='${PROJECT_NAME}-usage-plan'].id" --output text 2>/dev/null)
    for UP_ID in $USAGE_PLANS; do
        # Remove API stages from usage plan
        aws apigateway update-usage-plan \
            --usage-plan-id "$UP_ID" \
            --patch-operations "op=remove,path=/apiStages,value=${API_ID}:dev" \
            --region "$REGION" > /dev/null 2>&1 || true
        aws apigateway delete-usage-plan --usage-plan-id "$UP_ID" --region "$REGION" > /dev/null 2>&1
        log_success "Deleted usage plan"
    done

    # Delete API keys
    API_KEY_IDS=$(aws apigateway get-api-keys \
        --name-query "${PROJECT_NAME}-api-key" \
        --region "$REGION" \
        --query 'items[].id' --output text 2>/dev/null)
    for KEY_ID in $API_KEY_IDS; do
        aws apigateway delete-api-key --api-key "$KEY_ID" --region "$REGION" > /dev/null 2>&1
        log_success "Deleted API key"
    done

    aws apigateway delete-rest-api --rest-api-id "$API_ID" --region "$REGION" > /dev/null 2>&1
    log_success "Deleted API Gateway $API_NAME"
else
    log_warn "API Gateway not found"
fi

###############################################################################
# PHASE 4: Delete RDS Instances
###############################################################################

log_phase "PHASE 4: DELETING RDS INSTANCES"

for DB_ID in keycloak-provider-db keycloak-consumer-db opendata-db; do
    log_step "Deleting RDS instance: $DB_ID"
    aws rds delete-db-instance \
        --db-instance-identifier "$DB_ID" \
        --skip-final-snapshot \
        --delete-automated-backups \
        --region "$REGION" > /dev/null 2>&1 \
        && log_success "Deleting $DB_ID (this takes several minutes)" || log_warn "$DB_ID not found"
done

log_info "RDS deletion is asynchronous. Waiting for instances to be deleted..."
for DB_ID in keycloak-provider-db keycloak-consumer-db opendata-db; do
    aws rds wait db-instance-deleted \
        --db-instance-identifier "$DB_ID" \
        --region "$REGION" 2>/dev/null || log_warn "Timeout waiting for $DB_ID deletion"
done

# Delete DB subnet group
aws rds delete-db-subnet-group \
    --db-subnet-group-name "${PROJECT_NAME}-db-subnet-group" \
    --region "$REGION" > /dev/null 2>&1 \
    && log_success "Deleted DB subnet group" || log_warn "DB subnet group not found"

###############################################################################
# PHASE 5: Delete Secrets
###############################################################################

log_phase "PHASE 5: DELETING SECRETS"

SECRETS=$(aws secretsmanager list-secrets \
    --region "$REGION" \
    --query "SecretList[?starts_with(Name, '${PROJECT_NAME}/')].Name" --output text 2>/dev/null)

for SECRET in $SECRETS; do
    aws secretsmanager delete-secret \
        --secret-id "$SECRET" \
        --force-delete-without-recovery \
        --region "$REGION" > /dev/null 2>&1
    log_success "Deleted secret: $SECRET"
done

if [ -z "$SECRETS" ]; then
    log_warn "No secrets found with prefix ${PROJECT_NAME}/"
fi

###############################################################################
# PHASE 6: Delete Security Groups
###############################################################################

log_phase "PHASE 6: DELETING SECURITY GROUPS"

# Delete in correct order (reverse dependency)
for SG_NAME in "${PROJECT_NAME}-ecs-sg" "${PROJECT_NAME}-rds-sg" "${PROJECT_NAME}-opendata-rds-sg" "${PROJECT_NAME}-alb-sg"; do
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
        --region "$REGION" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

    if [ ! -z "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        # Remove all ingress/egress rules referencing this SG from other SGs
        aws ec2 revoke-security-group-ingress \
            --group-id "$SG_ID" \
            --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" \
            --region "$REGION" > /dev/null 2>&1 || true

        aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" > /dev/null 2>&1 \
            && log_success "Deleted security group $SG_NAME ($SG_ID)" \
            || log_warn "Could not delete $SG_NAME (may have dependencies)"
    else
        log_warn "Security group $SG_NAME not found"
    fi
done

###############################################################################
# PHASE 7: Delete IAM Roles & Policies
###############################################################################

log_phase "PHASE 7: DELETING IAM ROLES & POLICIES"

delete_role_with_policies() {
    local role_name=$1
    log_step "Deleting role: $role_name"

    # Detach managed policies
    POLICIES=$(aws iam list-attached-role-policies \
        --role-name "$role_name" \
        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
    for POLICY_ARN in $POLICIES; do
        aws iam detach-role-policy --role-name "$role_name" --policy-arn "$POLICY_ARN" 2>/dev/null
    done

    # Delete inline policies
    INLINE=$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text 2>/dev/null)
    for POLICY_NAME in $INLINE; do
        aws iam delete-role-policy --role-name "$role_name" --policy-name "$POLICY_NAME" 2>/dev/null
    done

    aws iam delete-role --role-name "$role_name" 2>/dev/null \
        && log_success "Deleted role $role_name" || log_warn "Role $role_name not found"
}

delete_role_with_policies "${PROJECT_NAME}-keycloak-execution-role"
delete_role_with_policies "${PROJECT_NAME}-keycloak-task-role"
delete_role_with_policies "${PROJECT_NAME}-lambda-execution-role"

# Delete custom policies
for POLICY_NAME in "${PROJECT_NAME}-secrets-access" "${PROJECT_NAME}-lambda-secrets-access"; do
    POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
    aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null \
        && log_success "Deleted policy $POLICY_NAME" || log_warn "Policy $POLICY_NAME not found"
done

###############################################################################
# PHASE 8: Delete CloudWatch Log Groups
###############################################################################

log_phase "PHASE 8: DELETING CLOUDWATCH LOG GROUPS"

for LOG_GROUP in "/ecs/keycloak-provider" "/ecs/keycloak-consumer" "/aws/lambda/denodo-permissions-api"; do
    aws logs delete-log-group \
        --log-group-name "$LOG_GROUP" \
        --region "$REGION" > /dev/null 2>&1 \
        && log_success "Deleted log group $LOG_GROUP" || log_warn "Log group $LOG_GROUP not found"
done

###############################################################################
# PHASE 9: Cleanup local files
###############################################################################

log_phase "PHASE 9: CLEANUP LOCAL FILES"

if [ -f "$DEPLOYMENT_INFO" ]; then
    mv "$DEPLOYMENT_INFO" "${DEPLOYMENT_INFO}.bak"
    log_success "Backed up deployment-info.json to deployment-info.json.bak"
fi

rm -f /tmp/ecs-trust-policy.json /tmp/secrets-policy.json /tmp/lambda-trust-policy.json
rm -f /tmp/lambda-secrets-policy.json /tmp/lambda-permissions-api.zip
rm -f /tmp/keycloak-provider-task.json /tmp/keycloak-consumer-task.json

log_success "Temporary files cleaned up"

###############################################################################
# SUMMARY
###############################################################################

echo ""
log_phase "✓ CLEANUP COMPLETE"
echo ""
echo "All $PROJECT_NAME resources have been deleted:"
echo "  ✓ ECS Services, Task Definitions, Cluster"
echo "  ✓ ALB, Listeners, Target Groups"
echo "  ✓ Lambda Function, API Gateway"
echo "  ✓ RDS Instances, DB Subnet Groups"
echo "  ✓ Secrets Manager Secrets"
echo "  ✓ Security Groups"
echo "  ✓ IAM Roles and Policies"
echo "  ✓ CloudWatch Log Groups"
echo ""
echo -e "${YELLOW}Note:${NC} The VPC, subnets, and Denodo EC2 instance were NOT deleted."
echo -e "${YELLOW}Note:${NC} deployment-info.json was backed up to deployment-info.json.bak"
echo ""
