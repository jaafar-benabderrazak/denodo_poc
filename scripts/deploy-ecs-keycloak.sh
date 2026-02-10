#!/bin/bash
###############################################################################
# Denodo Keycloak POC - ECS & ALB Deployment Script
#
# This script deploys ECS cluster, Keycloak services, and Application Load
# Balancer. It reads deployment-info.json created by deploy-denodo-keycloak.sh.
#
# Prerequisites:
# - Run deploy-denodo-keycloak.sh first (or deploy-step-by-step.sh)
# - deployment-info.json must exist in the project root
#
# Usage: ./scripts/deploy-ecs-keycloak.sh
#
# Date: February 2026
# Author: Jaafar Benabderrazak
###############################################################################

set -e
trap 'echo -e "\033[0;31m[FATAL] Script failed at line $LINENO. Command: $BASH_COMMAND\033[0m"' ERR

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENT_INFO="$PROJECT_DIR/deployment-info.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Logging
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_phase() { echo -e "\n${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"; echo -e "${MAGENTA}║ $1${NC}"; echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}\n"; }
log_step() { echo -e "${CYAN}▶ STEP $1:${NC} $2"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }

###############################################################################
# PHASE 0: Read deployment info
###############################################################################

log_phase "PHASE 0: READING DEPLOYMENT INFO"

if [ ! -f "$DEPLOYMENT_INFO" ]; then
    log_error "deployment-info.json not found at $DEPLOYMENT_INFO"
    log_error "Run deploy-denodo-keycloak.sh or deploy-step-by-step.sh first"
    exit 1
fi

REGION=$(jq -r '.region' "$DEPLOYMENT_INFO")
VPC_ID=$(jq -r '.vpcId' "$DEPLOYMENT_INFO")
ACCOUNT_ID=$(jq -r '.accountId' "$DEPLOYMENT_INFO")
PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO")
ALB_SG_ID=$(jq -r '.securityGroups.alb' "$DEPLOYMENT_INFO")
ECS_SG_ID=$(jq -r '.securityGroups.ecs' "$DEPLOYMENT_INFO")
PRIVATE_SUBNET_1=$(jq -r '.subnets.private[0]' "$DEPLOYMENT_INFO")
PRIVATE_SUBNET_2=$(jq -r '.subnets.private[1]' "$DEPLOYMENT_INFO")
PUBLIC_SUBNET_1=$(jq -r '.subnets.public[0]' "$DEPLOYMENT_INFO")
PUBLIC_SUBNET_2=$(jq -r '.subnets.public[1]' "$DEPLOYMENT_INFO")
PROVIDER_DB_ENDPOINT=$(jq -r '.rdsEndpoints.provider' "$DEPLOYMENT_INFO")
CONSUMER_DB_ENDPOINT=$(jq -r '.rdsEndpoints.consumer' "$DEPLOYMENT_INFO")

ECS_CLUSTER_NAME="denodo-keycloak-cluster"

log_success "Region: $REGION"
log_success "Account: $ACCOUNT_ID"
log_success "VPC: $VPC_ID"
log_success "ECS SG: $ECS_SG_ID"
log_success "ALB SG: $ALB_SG_ID"

###############################################################################
# PHASE 1: IAM Roles
###############################################################################

log_phase "PHASE 1: CREATING IAM ROLES"

EXECUTION_ROLE_NAME="${PROJECT_NAME}-keycloak-execution-role"
TASK_ROLE_NAME="${PROJECT_NAME}-keycloak-task-role"

log_step "1.1" "Creating ECS execution role"

# Trust policy for ECS
cat > /tmp/ecs-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
    --role-name "$EXECUTION_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/ecs-trust-policy.json \
    --tags Key=Project,Value="$PROJECT_NAME" \
    2>&1 || log_warn "Execution role already exists"

# Attach managed policy for ECS execution
aws iam attach-role-policy \
    --role-name "$EXECUTION_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    2>&1 || log_warn "ECS execution policy already attached"

# Custom policy for Secrets Manager access
cat > /tmp/secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${PROJECT_NAME}/*"
    }
  ]
}
EOF

SECRETS_POLICY_ARN=$(aws iam create-policy \
    --policy-name "${PROJECT_NAME}-secrets-access" \
    --policy-document file:///tmp/secrets-policy.json \
    --query 'Policy.Arn' --output text 2>/dev/null || \
    echo "arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT_NAME}-secrets-access")

aws iam attach-role-policy \
    --role-name "$EXECUTION_ROLE_NAME" \
    --policy-arn "$SECRETS_POLICY_ARN" \
    2>&1 || log_warn "Secrets policy already attached"

log_success "Execution role: $EXECUTION_ROLE_NAME"

log_step "1.2" "Creating ECS task role"

aws iam create-role \
    --role-name "$TASK_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/ecs-trust-policy.json \
    --tags Key=Project,Value="$PROJECT_NAME" \
    2>&1 || log_warn "Task role already exists"

# Task role needs minimal permissions (Keycloak doesn't call AWS APIs)
log_success "Task role: $TASK_ROLE_NAME"

EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXECUTION_ROLE_NAME}"
TASK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE_NAME}"

# Wait for IAM propagation
log_info "Waiting 10s for IAM role propagation..."
sleep 10

###############################################################################
# PHASE 2: CloudWatch Log Groups
###############################################################################

log_phase "PHASE 2: CREATING CLOUDWATCH LOG GROUPS"

log_step "2.1" "Creating log groups"

aws logs create-log-group \
    --log-group-name "/ecs/keycloak-provider" \
    --region "$REGION" \
    --tags Project="$PROJECT_NAME" \
    2>&1 || log_warn "Provider log group already exists"

aws logs create-log-group \
    --log-group-name "/ecs/keycloak-consumer" \
    --region "$REGION" \
    --tags Project="$PROJECT_NAME" \
    2>&1 || log_warn "Consumer log group already exists"

# Set retention to 30 days
aws logs put-retention-policy \
    --log-group-name "/ecs/keycloak-provider" \
    --retention-in-days 30 \
    --region "$REGION" 2>&1 || true

aws logs put-retention-policy \
    --log-group-name "/ecs/keycloak-consumer" \
    --retention-in-days 30 \
    --region "$REGION" 2>&1 || true

log_success "Log groups created with 30-day retention"

###############################################################################
# PHASE 3: ECS Cluster
###############################################################################

log_phase "PHASE 3: CREATING ECS CLUSTER"

log_step "3.1" "Creating ECS cluster"

aws ecs create-cluster \
    --cluster-name "$ECS_CLUSTER_NAME" \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --settings name=containerInsights,value=enabled \
    --tags key=Project,value="$PROJECT_NAME" key=Environment,value=dev \
    --region "$REGION" \
    2>&1 || log_warn "ECS cluster already exists"

log_success "ECS Cluster: $ECS_CLUSTER_NAME"

###############################################################################
# PHASE 4: Register Task Definitions
###############################################################################

log_phase "PHASE 4: REGISTERING TASK DEFINITIONS"

# Get actual secret ARNs (need the random suffix)
get_secret_arn() {
    aws secretsmanager describe-secret \
        --secret-id "$1" \
        --region "$REGION" \
        --query 'ARN' --output text 2>&1
}

PROVIDER_DB_SECRET_ARN=$(get_secret_arn "${PROJECT_NAME}/keycloak/provider/db")
CONSUMER_DB_SECRET_ARN=$(get_secret_arn "${PROJECT_NAME}/keycloak/consumer/db")
ADMIN_SECRET_ARN=$(get_secret_arn "${PROJECT_NAME}/keycloak/admin")

log_info "Provider DB Secret ARN: $PROVIDER_DB_SECRET_ARN"
log_info "Consumer DB Secret ARN: $CONSUMER_DB_SECRET_ARN"
log_info "Admin Secret ARN: $ADMIN_SECRET_ARN"

log_step "4.1" "Registering Keycloak Provider task definition"

cat > /tmp/keycloak-provider-task.json <<EOF
{
  "family": "keycloak-provider",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "executionRoleArn": "${EXECUTION_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "keycloak",
      "image": "quay.io/keycloak/keycloak:23.0",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {"name": "KC_DB", "value": "postgres"},
        {"name": "KC_DB_URL_DATABASE", "value": "postgres"},
        {"name": "KC_DB_USERNAME", "value": "keycloak"},
        {"name": "KC_DB_URL_HOST", "value": "${PROVIDER_DB_ENDPOINT}"},
        {"name": "KC_HOSTNAME_STRICT", "value": "false"},
        {"name": "KC_HTTP_RELATIVE_PATH", "value": "/auth"},
        {"name": "KC_HOSTNAME_STRICT_HTTPS", "value": "false"},
        {"name": "KC_HTTP_ENABLED", "value": "true"},
        {"name": "KC_PROXY", "value": "edge"},
        {"name": "KC_HEALTH_ENABLED", "value": "true"},
        {"name": "KC_METRICS_ENABLED", "value": "true"},
        {"name": "KEYCLOAK_ADMIN", "value": "admin"}
      ],
      "secrets": [
        {
          "name": "KC_DB_PASSWORD",
          "valueFrom": "${PROVIDER_DB_SECRET_ARN}:password::"
        },
        {
          "name": "KEYCLOAK_ADMIN_PASSWORD",
          "valueFrom": "${ADMIN_SECRET_ARN}:password::"
        }
      ],
      "command": ["start"],
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8080/auth/health/ready || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 300
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/keycloak-provider",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "keycloak"
        }
      }
    }
  ]
}
EOF

PROVIDER_TASK_ARN=$(aws ecs register-task-definition \
    --cli-input-json file:///tmp/keycloak-provider-task.json \
    --region "$REGION" \
    --query 'taskDefinition.taskDefinitionArn' --output text)

log_success "Provider task definition: $PROVIDER_TASK_ARN"

log_step "4.2" "Registering Keycloak Consumer task definition"

cat > /tmp/keycloak-consumer-task.json <<EOF
{
  "family": "keycloak-consumer",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "executionRoleArn": "${EXECUTION_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "keycloak",
      "image": "quay.io/keycloak/keycloak:23.0",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {"name": "KC_DB", "value": "postgres"},
        {"name": "KC_DB_URL_DATABASE", "value": "postgres"},
        {"name": "KC_DB_USERNAME", "value": "keycloak"},
        {"name": "KC_DB_URL_HOST", "value": "${CONSUMER_DB_ENDPOINT}"},
        {"name": "KC_HOSTNAME_STRICT", "value": "false"},
        {"name": "KC_HTTP_RELATIVE_PATH", "value": "/auth"},
        {"name": "KC_HOSTNAME_STRICT_HTTPS", "value": "false"},
        {"name": "KC_HTTP_ENABLED", "value": "true"},
        {"name": "KC_PROXY", "value": "edge"},
        {"name": "KC_HEALTH_ENABLED", "value": "true"},
        {"name": "KC_METRICS_ENABLED", "value": "true"},
        {"name": "KEYCLOAK_ADMIN", "value": "admin"}
      ],
      "secrets": [
        {
          "name": "KC_DB_PASSWORD",
          "valueFrom": "${CONSUMER_DB_SECRET_ARN}:password::"
        },
        {
          "name": "KEYCLOAK_ADMIN_PASSWORD",
          "valueFrom": "${ADMIN_SECRET_ARN}:password::"
        }
      ],
      "command": ["start"],
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8080/auth/health/ready || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 300
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/keycloak-consumer",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "keycloak"
        }
      }
    }
  ]
}
EOF

CONSUMER_TASK_ARN=$(aws ecs register-task-definition \
    --cli-input-json file:///tmp/keycloak-consumer-task.json \
    --region "$REGION" \
    --query 'taskDefinition.taskDefinitionArn' --output text)

log_success "Consumer task definition: $CONSUMER_TASK_ARN"

###############################################################################
# PHASE 5: Application Load Balancer
###############################################################################

log_phase "PHASE 5: CREATING APPLICATION LOAD BALANCER"

log_step "5.1" "Creating ALB"

log_info "Public subnet 1: $PUBLIC_SUBNET_1"
log_info "Public subnet 2: $PUBLIC_SUBNET_2"
log_info "ALB SG: $ALB_SG_ID"

# Check if ALB already exists (stderr suppressed here intentionally - we check exit code)
if aws elbv2 describe-load-balancers --names keycloak-alb --region "$REGION" > /dev/null 2>&1; then
    ALB_ARN=$(aws elbv2 describe-load-balancers \
        --names keycloak-alb \
        --region "$REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    log_warn "ALB keycloak-alb already exists"
else
    log_info "Creating new ALB..."
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name keycloak-alb \
        --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" \
        --security-groups "$ALB_SG_ID" \
        --scheme internet-facing \
        --type application \
        --ip-address-type ipv4 \
        --tags Key=Project,Value="$PROJECT_NAME" Key=Environment,Value=dev \
        --region "$REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --region "$REGION" \
    --query 'LoadBalancers[0].DNSName' --output text)

log_success "ALB ARN: $ALB_ARN"
log_success "ALB DNS: $ALB_DNS"

log_step "5.2" "Creating target groups"

# Provider target group
PROVIDER_TG_ARN=$(aws elbv2 create-target-group \
    --name keycloak-provider-tg \
    --protocol HTTP \
    --port 8080 \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-enabled \
    --health-check-path "/auth/health/ready" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 10 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --tags Key=Project,Value="$PROJECT_NAME" \
    --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || \
    aws elbv2 describe-target-groups \
        --names keycloak-provider-tg \
        --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' --output text)

# Force update health check path for existing Target Groups
aws elbv2 modify-target-group --target-group-arn "$PROVIDER_TG_ARN" --health-check-path "/auth/health/ready" >/dev/null 2>&1

log_success "Provider TG: $PROVIDER_TG_ARN"

# Consumer target group
CONSUMER_TG_ARN=$(aws elbv2 create-target-group \
    --name keycloak-consumer-tg \
    --protocol HTTP \
    --port 8080 \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-enabled \
    --health-check-path "/auth/health/ready" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 10 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --tags Key=Project,Value="$PROJECT_NAME" \
    --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || \
    aws elbv2 describe-target-groups \
        --names keycloak-consumer-tg \
        --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' --output text)

# Force update health check path for existing Target Groups
aws elbv2 modify-target-group --target-group-arn "$CONSUMER_TG_ARN" --health-check-path "/auth/health/ready" >/dev/null 2>&1

log_success "Consumer TG: $CONSUMER_TG_ARN"

log_step "5.3" "Creating HTTP listener with routing rules"

# Default action: return 404 for unmatched paths
LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=fixed-response,FixedResponseConfig="{StatusCode=404,ContentType=text/plain,MessageBody=Not Found}" \
    --region "$REGION" \
    --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || \
    aws elbv2 describe-listeners \
        --load-balancer-arn "$ALB_ARN" \
        --region "$REGION" \
        --query 'Listeners[0].ListenerArn' --output text)

log_success "Listener ARN: $LISTENER_ARN"

# Rule 1: Route /auth/realms/denodo-idp/* to Provider
aws elbv2 create-rule \
    --listener-arn "$LISTENER_ARN" \
    --priority 10 \
    --conditions Field=path-pattern,Values='/auth/realms/denodo-idp/*' \
    --actions Type=forward,TargetGroupArn="$PROVIDER_TG_ARN" \
    --region "$REGION" 2>&1 || log_warn "Provider path rule already exists"

# Rule 2: Route /auth/realms/master/* to Provider (admin console)
aws elbv2 create-rule \
    --listener-arn "$LISTENER_ARN" \
    --priority 15 \
    --conditions Field=path-pattern,Values='/auth/admin/*' \
    --actions Type=forward,TargetGroupArn="$PROVIDER_TG_ARN" \
    --region "$REGION" 2>&1 || log_warn "Admin path rule already exists"

# Rule 3: Route /auth/realms/denodo-consumer/* to Consumer
aws elbv2 create-rule \
    --listener-arn "$LISTENER_ARN" \
    --priority 20 \
    --conditions Field=path-pattern,Values='/auth/realms/denodo-consumer/*' \
    --actions Type=forward,TargetGroupArn="$CONSUMER_TG_ARN" \
    --region "$REGION" 2>&1 || log_warn "Consumer path rule already exists"

# Rule 4: Route /health/* to Provider (general health)
aws elbv2 create-rule \
    --listener-arn "$LISTENER_ARN" \
    --priority 30 \
    --conditions Field=path-pattern,Values='/auth/health/*' \
    --actions Type=forward,TargetGroupArn="$PROVIDER_TG_ARN" \
    --region "$REGION" 2>&1 || log_warn "Health path rule already exists"

log_success "Path-based routing rules configured"

###############################################################################
# PHASE 6: ECS Services
###############################################################################

log_phase "PHASE 6: CREATING ECS SERVICES"

log_step "6.1" "Creating Keycloak Provider service"

aws ecs create-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service-name keycloak-provider \
    --task-definition keycloak-provider \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$PUBLIC_SUBNET_1,$PUBLIC_SUBNET_2],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$PROVIDER_TG_ARN,containerName=keycloak,containerPort=8080" \
    --health-check-grace-period-seconds 300 \
    --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100" \
    --tags key=Project,value="$PROJECT_NAME" key=Component,value=keycloak-provider \
    --region "$REGION" 2>&1 || \
    (log_warn "Provider service already exists, updating..." && \
     aws ecs update-service \
        --cluster "$ECS_CLUSTER_NAME" \
        --service keycloak-provider \
        --task-definition keycloak-provider \
        --network-configuration "awsvpcConfiguration={subnets=[$PUBLIC_SUBNET_1,$PUBLIC_SUBNET_2],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}" \
        --region "$REGION" > /dev/null)

log_success "Keycloak Provider service created"

log_step "6.2" "Creating Keycloak Consumer service"

aws ecs create-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service-name keycloak-consumer \
    --task-definition keycloak-consumer \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$PUBLIC_SUBNET_1,$PUBLIC_SUBNET_2],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$CONSUMER_TG_ARN,containerName=keycloak,containerPort=8080" \
    --health-check-grace-period-seconds 300 \
    --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100" \
    --tags key=Project,value="$PROJECT_NAME" key=Component,value=keycloak-consumer \
    --region "$REGION" 2>&1 || \
    (log_warn "Consumer service already exists, updating..." && \
     aws ecs update-service \
        --cluster "$ECS_CLUSTER_NAME" \
        --service keycloak-consumer \
        --task-definition keycloak-consumer \
        --network-configuration "awsvpcConfiguration={subnets=[$PUBLIC_SUBNET_1,$PUBLIC_SUBNET_2],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}" \
        --region "$REGION" > /dev/null)

log_success "Keycloak Consumer service created"

log_step "6.3" "Waiting for services to reach steady state"
log_info "⏱ This may take 5-10 minutes (Keycloak startup time)..."

aws ecs wait services-stable \
    --cluster "$ECS_CLUSTER_NAME" \
    --services keycloak-provider keycloak-consumer \
    --region "$REGION" 2>&1 || log_warn "Timeout waiting for services (they may still be starting)"

log_success "ECS services deployed"

###############################################################################
# PHASE 7: Update deployment-info.json
###############################################################################

log_phase "PHASE 7: UPDATING DEPLOYMENT INFO"

# Update deployment-info.json with new resources
UPDATED_INFO=$(jq \
    --arg alb_arn "$ALB_ARN" \
    --arg alb_dns "$ALB_DNS" \
    --arg provider_tg "$PROVIDER_TG_ARN" \
    --arg consumer_tg "$CONSUMER_TG_ARN" \
    --arg listener "$LISTENER_ARN" \
    --arg exec_role "$EXECUTION_ROLE_ARN" \
    --arg task_role "$TASK_ROLE_ARN" \
    --arg cluster "$ECS_CLUSTER_NAME" \
    '. + {
        "ecsCluster": $cluster,
        "alb": {
            "arn": $alb_arn,
            "dns": $alb_dns,
            "listenerArn": $listener
        },
        "targetGroups": {
            "provider": $provider_tg,
            "consumer": $consumer_tg
        },
        "iamRoles": {
            "executionRole": $exec_role,
            "taskRole": $task_role
        },
        "keycloakUrls": {
            "providerAdmin": ("http://" + $alb_dns + "/auth/admin"),
            "providerRealm": ("http://" + $alb_dns + "/auth/realms/denodo-idp"),
            "consumerRealm": ("http://" + $alb_dns + "/auth/realms/denodo-consumer"),
            "health": ("http://" + $alb_dns + "/auth/health/ready")
        }
    }' "$DEPLOYMENT_INFO")

echo "$UPDATED_INFO" > "$DEPLOYMENT_INFO"

log_success "deployment-info.json updated"

###############################################################################
# SUMMARY
###############################################################################

echo ""
log_phase "✓ ECS & ALB DEPLOYMENT COMPLETE"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ECS DEPLOYMENT SUMMARY                        ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Resources Created:"
echo "  ✓ 2 IAM Roles (execution + task)"
echo "  ✓ 2 CloudWatch Log Groups (30-day retention)"
echo "  ✓ 1 ECS Cluster ($ECS_CLUSTER_NAME)"
echo "  ✓ 2 Task Definitions (provider + consumer)"
echo "  ✓ 1 Application Load Balancer (keycloak-alb)"
echo "  ✓ 2 Target Groups (provider + consumer)"
echo "  ✓ 4 Path-based routing rules"
echo "  ✓ 2 ECS Services (keycloak-provider + keycloak-consumer)"
echo ""
echo "Access URLs:"
echo "  • Keycloak Admin: http://$ALB_DNS/auth/admin"
echo "  • Provider Realm: http://$ALB_DNS/auth/realms/denodo-idp"
echo "  • Consumer Realm: http://$ALB_DNS/auth/realms/denodo-consumer"
echo "  • Health Check:   http://$ALB_DNS/health/ready"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Wait 3-5 minutes for Keycloak to fully start"
echo "  2. Run: ./scripts/configure-keycloak.sh (to configure OIDC federation)"
echo "  3. Run: ./scripts/deploy-lambda-api.sh (to deploy authorization API)"
echo ""

# Cleanup temp files
rm -f /tmp/ecs-trust-policy.json /tmp/secrets-policy.json
rm -f /tmp/keycloak-provider-task.json /tmp/keycloak-consumer-task.json
