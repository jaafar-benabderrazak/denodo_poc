#!/bin/bash
###############################################################################
# Deployment Status Checker
# Checks what components have been deployed in the Denodo POC
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
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${CYAN}═══════════════════════════════════════════${NC}"; echo -e "${CYAN} $1${NC}"; echo -e "${CYAN}═══════════════════════════════════════════${NC}\n"; }

check_mark() { echo -e "${GREEN}✓${NC}"; }
cross_mark() { echo -e "${RED}✗${NC}"; }
pending_mark() { echo -e "${YELLOW}○${NC}"; }

echo ""
log_section "DENODO POC DEPLOYMENT STATUS"

REGION="eu-west-3"
PROJECT_NAME="denodo-poc"

if [ -f "$DEPLOYMENT_INFO" ]; then
    REGION=$(jq -r '.region' "$DEPLOYMENT_INFO" 2>/dev/null || echo "eu-west-3")
    PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO" 2>/dev/null || echo "denodo-poc")
    log_info "Using deployment-info.json"
else
    log_warn "deployment-info.json not found - checking AWS resources directly"
fi

echo ""

###############################################################################
# 1. VPC & Networking
###############################################################################
log_section "1. VPC & NETWORKING"

VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=*denodo*" \
    --region "$REGION" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || echo "None")

if [ "$VPC_ID" != "None" ] && [ ! -z "$VPC_ID" ]; then
    echo -e "$(check_mark) VPC: $VPC_ID"
else
    echo -e "$(cross_mark) VPC: Not found"
fi

# Security Groups
SG_COUNT=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
    --region "$REGION" \
    --query 'length(SecurityGroups)' \
    --output text 2>/dev/null || echo "0")

if [ "$SG_COUNT" -gt "0" ]; then
    echo -e "$(check_mark) Security Groups: $SG_COUNT found"
    aws ec2 describe-security-groups \
        --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
        --region "$REGION" \
        --query 'SecurityGroups[].[GroupName,GroupId]' \
        --output text 2>/dev/null | while read name id; do
        echo "    - $name ($id)"
    done
else
    echo -e "$(cross_mark) Security Groups: None found"
fi

###############################################################################
# 2. RDS Databases
###############################################################################
log_section "2. RDS DATABASES"

RDS_INSTANCES=$(aws rds describe-db-instances \
    --region "$REGION" \
    --query "DBInstances[?contains(DBInstanceIdentifier, '${PROJECT_NAME}')].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Endpoint:Endpoint.Address,Engine:Engine}" \
    --output json 2>/dev/null || echo "[]")

RDS_COUNT=$(echo "$RDS_INSTANCES" | jq 'length')

if [ "$RDS_COUNT" -gt "0" ]; then
    echo -e "$(check_mark) RDS Instances: $RDS_COUNT found"
    echo "$RDS_INSTANCES" | jq -r '.[] | "    - \(.ID): \(.Status) (\(.Engine))"'
    
    # Check OpenData database content
    OPENDATA_DB=$(echo "$RDS_INSTANCES" | jq -r '.[] | select(.ID | contains("opendata")) | .ID' | head -1)
    if [ ! -z "$OPENDATA_DB" ] && [ "$OPENDATA_DB" != "null" ]; then
        echo ""
        echo "  Checking OpenData database content..."
        
        DB_PASSWORD=$(aws secretsmanager get-secret-value \
            --secret-id "${PROJECT_NAME}/opendata/db" \
            --region "$REGION" \
            --query SecretString --output text 2>/dev/null | jq -r '.password' 2>/dev/null || echo "")
        
        if [ ! -z "$DB_PASSWORD" ]; then
            OPENDATA_ENDPOINT=$(echo "$RDS_INSTANCES" | jq -r '.[] | select(.ID | contains("opendata")) | .Endpoint' | head -1)
            
            # Try direct connection (will fail in CloudShell, but worth trying)
            TABLE_COUNT=$(PGPASSWORD="$DB_PASSWORD" psql -h "$OPENDATA_ENDPOINT" -U denodo -d opendata -p 5432 -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'opendata';" 2>/dev/null | xargs || echo "N/A")
            
            if [ "$TABLE_COUNT" != "N/A" ] && [ "$TABLE_COUNT" -gt "0" ]; then
                echo -e "    $(check_mark) OpenData schema: $TABLE_COUNT tables"
            else
                echo -e "    $(pending_mark) OpenData schema: Unable to check (run from EC2 or use SSM)"
            fi
        fi
    fi
else
    echo -e "$(cross_mark) RDS Instances: None found"
fi

###############################################################################
# 3. ECS Cluster & Services
###############################################################################
log_section "3. ECS CLUSTER & SERVICES"

CLUSTER_ARN=$(aws ecs describe-clusters \
    --clusters "denodo-keycloak-cluster" \
    --region "$REGION" \
    --query 'clusters[0].clusterArn' \
    --output text 2>/dev/null || echo "None")

if [ "$CLUSTER_ARN" != "None" ] && [ ! -z "$CLUSTER_ARN" ]; then
    echo -e "$(check_mark) ECS Cluster: denodo-keycloak-cluster"
    
    # Check services
    SERVICES=$(aws ecs list-services \
        --cluster denodo-keycloak-cluster \
        --region "$REGION" \
        --query 'serviceArns[]' \
        --output json 2>/dev/null || echo "[]")
    
    SERVICE_COUNT=$(echo "$SERVICES" | jq 'length')
    
    if [ "$SERVICE_COUNT" -gt "0" ]; then
        echo -e "$(check_mark) ECS Services: $SERVICE_COUNT found"
        
        SERVICE_NAMES=$(echo "$SERVICES" | jq -r '.[]' | xargs -I {} basename {})
        for svc in $SERVICE_NAMES; do
            SERVICE_INFO=$(aws ecs describe-services \
                --cluster denodo-keycloak-cluster \
                --services "$svc" \
                --region "$REGION" \
                --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' \
                --output json 2>/dev/null)
            
            STATUS=$(echo "$SERVICE_INFO" | jq -r '.Status')
            RUNNING=$(echo "$SERVICE_INFO" | jq -r '.Running')
            DESIRED=$(echo "$SERVICE_INFO" | jq -r '.Desired')
            
            if [ "$RUNNING" == "$DESIRED" ] && [ "$RUNNING" -gt "0" ]; then
                echo -e "    $(check_mark) $svc: $RUNNING/$DESIRED tasks ($STATUS)"
            else
                echo -e "    $(cross_mark) $svc: $RUNNING/$DESIRED tasks ($STATUS)"
            fi
        done
    else
        echo -e "$(cross_mark) ECS Services: None found"
    fi
    
    # Check task definitions
    TASK_DEFS=$(aws ecs list-task-definitions \
        --family-prefix "keycloak" \
        --region "$REGION" \
        --query 'taskDefinitionArns[]' \
        --output json 2>/dev/null | jq 'length')
    
    if [ "$TASK_DEFS" -gt "0" ]; then
        echo -e "$(check_mark) Task Definitions: $TASK_DEFS registered"
    else
        echo -e "$(pending_mark) Task Definitions: None found"
    fi
else
    echo -e "$(cross_mark) ECS Cluster: Not found"
fi

###############################################################################
# 4. Application Load Balancer
###############################################################################
log_section "4. APPLICATION LOAD BALANCER"

ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "keycloak-alb" \
    --region "$REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || echo "None")

if [ "$ALB_ARN" != "None" ] && [ ! -z "$ALB_ARN" ]; then
    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --names "keycloak-alb" \
        --region "$REGION" \
        --query 'LoadBalancers[0].DNSName' \
        --output text 2>/dev/null)
    
    ALB_STATE=$(aws elbv2 describe-load-balancers \
        --names "keycloak-alb" \
        --region "$REGION" \
        --query 'LoadBalancers[0].State.Code' \
        --output text 2>/dev/null)
    
    echo -e "$(check_mark) ALB: keycloak-alb ($ALB_STATE)"
    echo "    DNS: $ALB_DNS"
    
    # Check target groups
    TG_COUNT=$(aws elbv2 describe-target-groups \
        --load-balancer-arn "$ALB_ARN" \
        --region "$REGION" \
        --query 'length(TargetGroups)' \
        --output text 2>/dev/null || echo "0")
    
    if [ "$TG_COUNT" -gt "0" ]; then
        echo -e "$(check_mark) Target Groups: $TG_COUNT configured"
    else
        echo -e "$(cross_mark) Target Groups: None found"
    fi
else
    echo -e "$(cross_mark) ALB: Not found"
fi

###############################################################################
# 5. Lambda & API Gateway
###############################################################################
log_section "5. LAMBDA & API GATEWAY"

LAMBDA_ARN=$(aws lambda get-function \
    --function-name "denodo-permissions-api" \
    --region "$REGION" \
    --query 'Configuration.FunctionArn' \
    --output text 2>/dev/null || echo "None")

if [ "$LAMBDA_ARN" != "None" ] && [ ! -z "$LAMBDA_ARN" ]; then
    LAMBDA_STATE=$(aws lambda get-function \
        --function-name "denodo-permissions-api" \
        --region "$REGION" \
        --query 'Configuration.State' \
        --output text 2>/dev/null)
    
    echo -e "$(check_mark) Lambda: denodo-permissions-api ($LAMBDA_STATE)"
else
    echo -e "$(cross_mark) Lambda: Not found"
fi

# API Gateway
API_ID=$(aws apigatewayv2 get-apis \
    --region "$REGION" \
    --query "Items[?contains(Name, 'denodo')].ApiId" \
    --output text 2>/dev/null || echo "")

if [ ! -z "$API_ID" ] && [ "$API_ID" != "None" ]; then
    API_ENDPOINT=$(aws apigatewayv2 get-apis \
        --region "$REGION" \
        --query "Items[?contains(Name, 'denodo')].ApiEndpoint" \
        --output text 2>/dev/null)
    
    echo -e "$(check_mark) API Gateway: $API_ID"
    echo "    Endpoint: $API_ENDPOINT"
else
    echo -e "$(cross_mark) API Gateway: Not found"
fi

###############################################################################
# 6. Secrets Manager
###############################################################################
log_section "6. SECRETS MANAGER"

SECRETS=$(aws secretsmanager list-secrets \
    --region "$REGION" \
    --query "SecretList[?contains(Name, '${PROJECT_NAME}')].Name" \
    --output json 2>/dev/null || echo "[]")

SECRET_COUNT=$(echo "$SECRETS" | jq 'length')

if [ "$SECRET_COUNT" -gt "0" ]; then
    echo -e "$(check_mark) Secrets: $SECRET_COUNT found"
    echo "$SECRETS" | jq -r '.[]' | while read secret; do
        echo "    - $secret"
    done
else
    echo -e "$(cross_mark) Secrets: None found"
fi

###############################################################################
# Summary
###############################################################################
log_section "SUMMARY & NEXT STEPS"

echo "Components Status:"
echo ""

# Calculate what's deployed
COMPONENTS_DEPLOYED=0
TOTAL_COMPONENTS=6

[ "$VPC_ID" != "None" ] && [ ! -z "$VPC_ID" ] && COMPONENTS_DEPLOYED=$((COMPONENTS_DEPLOYED + 1))
[ "$RDS_COUNT" -gt "0" ] && COMPONENTS_DEPLOYED=$((COMPONENTS_DEPLOYED + 1))
[ "$CLUSTER_ARN" != "None" ] && [ ! -z "$CLUSTER_ARN" ] && COMPONENTS_DEPLOYED=$((COMPONENTS_DEPLOYED + 1))
[ "$ALB_ARN" != "None" ] && [ ! -z "$ALB_ARN" ] && COMPONENTS_DEPLOYED=$((COMPONENTS_DEPLOYED + 1))
[ "$LAMBDA_ARN" != "None" ] && [ ! -z "$LAMBDA_ARN" ] && COMPONENTS_DEPLOYED=$((COMPONENTS_DEPLOYED + 1))
[ "$SECRET_COUNT" -gt "0" ] && COMPONENTS_DEPLOYED=$((COMPONENTS_DEPLOYED + 1))

echo "Deployment Progress: $COMPONENTS_DEPLOYED/$TOTAL_COMPONENTS components"
echo ""

if [ "$RDS_COUNT" -gt "0" ] && [ "$CLUSTER_ARN" == "None" ]; then
    echo "$(pending_mark) Next Step: Deploy ECS Keycloak"
    echo "   Run: ./scripts/deploy-ecs-keycloak.sh"
elif [ "$CLUSTER_ARN" != "None" ] && [ "$LAMBDA_ARN" == "None" ]; then
    echo "$(pending_mark) Next Step: Configure Keycloak & Deploy Lambda"
    echo "   Run: ./scripts/configure-keycloak.sh"
    echo "   Then: ./scripts/deploy-lambda-api.sh"
elif [ "$COMPONENTS_DEPLOYED" -eq "$TOTAL_COMPONENTS" ]; then
    echo "$(check_mark) All components deployed!"
    echo "   Run tests: ./tests/test-all.sh"
else
    echo "$(pending_mark) Next Step: Start deployment"
    echo "   Run: ./scripts/deploy-step-by-step.sh"
fi

echo ""
