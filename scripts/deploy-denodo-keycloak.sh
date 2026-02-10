#!/bin/bash
###############################################################################
# Denodo Keycloak POC - Complete Deployment Script
# 
# This script deploys a complete Keycloak federation setup for Denodo POC:
# - 2 Keycloak instances on ECS Fargate (Provider + Consumer)
# - 3 RDS PostgreSQL databases
# - Application Load Balancer
# - Lambda Authorization API
# - OpenData sample datasets
# - OIDC federation configuration
#
# Prerequisites:
# - AWS CLI configured with appropriate permissions
# - Run from AWS CloudShell or terminal with AWS credentials
# - VPC vpc-08ffb9d90f07533d0 must exist
#
# Usage: ./deploy-denodo-keycloak.sh
#
# Date: February 5, 2026
# Author: Jaafar Benabderrazak
###############################################################################

set -e

# Error trap for debugging - prints the line number where the script fails
trap 'echo -e "\033[0;31m[FATAL] Script failed at line $LINENO. Command: $BASH_COMMAND\033[0m"' ERR

# Configuration
REGION="eu-west-3"
VPC_ID="vpc-08ffb9d90f07533d0"
ACCOUNT_ID="928902064673"
PROJECT_NAME="denodo-poc"
ECS_CLUSTER_NAME="denodo-keycloak-cluster"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${CYAN}========== $1 ==========${NC}\n"; }
log_step() { echo -e "${BLUE}[STEP $1/$2]${NC} $3"; }

# Progress tracking
TOTAL_STEPS=20
CURRENT_STEP=0

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    log_step $CURRENT_STEP $TOTAL_STEPS "$1"
}

###############################################################################
# PHASE 0: Prerequisites and Validation
###############################################################################

log_section "PHASE 0: PREREQUISITES CHECK"

step "Checking AWS CLI configuration"
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed"
    exit 1
fi

AWS_CLI_VERSION=$(aws --version 2>&1 | cut -d' ' -f1 | cut -d'/' -f2)
log_info "AWS CLI version: $AWS_CLI_VERSION"

step "Validating AWS credentials"
CALLER_IDENTITY=$(aws sts get-caller-identity --region $REGION 2>&1)
if [ $? -ne 0 ]; then
    log_error "AWS credentials are not configured properly"
    exit 1
fi

CURRENT_ACCOUNT=$(echo $CALLER_IDENTITY | jq -r '.Account')
if [ "$CURRENT_ACCOUNT" != "$ACCOUNT_ID" ]; then
    log_warn "Current account ($CURRENT_ACCOUNT) differs from expected ($ACCOUNT_ID)"
    read -p "Continue anyway? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        exit 1
    fi
else
    ACCOUNT_ID=$CURRENT_ACCOUNT
fi

log_info "Account ID: $ACCOUNT_ID"
log_info "Region: $REGION"

step "Checking required tools"
for tool in jq curl; do
    if ! command -v $tool &> /dev/null; then
        log_error "$tool is not installed"
        exit 1
    fi
done
log_info "All required tools are installed"

step "Validating VPC exists"
VPC_EXISTS=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION --query 'Vpcs[0].VpcId' --output text 2>&1 || echo "")
if [ -z "$VPC_EXISTS" ] || [ "$VPC_EXISTS" == "None" ]; then
    log_error "VPC $VPC_ID does not exist in region $REGION"
    exit 1
fi
log_info "VPC $VPC_ID validated"

step "Discovering subnets"
# Get private subnets (not public by name and MapPublicIpOnLaunch=false)
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region $REGION \
    --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' \
    --output json)

# Get public subnets: by MapPublicIpOnLaunch=true OR Name tag containing 'public'
# This catches subnets like "ADS VPC-subnet-public*" that have IGW routes but MapPublicIpOnLaunch=false
ALL_SUBNETS_JSON=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region $REGION \
    --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch,Name:Tags[?Key==`Name`].Value|[0]}' \
    --output json)

PUBLIC_SUBNETS=$(echo "$ALL_SUBNETS_JSON" | jq '[.[] | select(.Public == true or (.Name // "" | test("public";"i")))] | unique_by(.AZ) | [.[].Id]')

PRIVATE_SUBNET_COUNT=$(echo $PRIVATE_SUBNETS | jq '. | length')
PUBLIC_SUBNET_COUNT=$(echo $PUBLIC_SUBNETS | jq '. | length')

log_info "Found $PRIVATE_SUBNET_COUNT private subnets"
log_info "Found $PUBLIC_SUBNET_COUNT public subnets (by flag or name)"

if [ $PRIVATE_SUBNET_COUNT -lt 2 ]; then
    log_error "ECS Fargate requires at least 2 private subnets in different AZs"
    exit 1
fi

if [ $PUBLIC_SUBNET_COUNT -lt 2 ]; then
    log_error "ALB requires at least 2 public subnets in different AZs"
    log_error "Found subnets: $(echo $PUBLIC_SUBNETS | jq -r 'join(", ")')"
    exit 1
fi

# Extract subnet IDs
PRIVATE_SUBNET_1=$(echo $PRIVATE_SUBNETS | jq -r '.[0]')
PRIVATE_SUBNET_2=$(echo $PRIVATE_SUBNETS | jq -r '.[1]')
PUBLIC_SUBNET_1=$(echo $PUBLIC_SUBNETS | jq -r '.[0]')
PUBLIC_SUBNET_2=$(echo $PUBLIC_SUBNETS | jq -r '.[1]')

log_info "Using private subnets: $PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2"
log_info "Using public subnets: $PUBLIC_SUBNET_1, $PUBLIC_SUBNET_2"

###############################################################################
# PHASE 1: Security Groups
###############################################################################

log_section "PHASE 1: CREATING SECURITY GROUPS"

step "Creating ALB Security Group"
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-keycloak-alb-sg" \
    --description "Security group for Keycloak ALB" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --output text --query 'GroupId' 2>&1 || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT_NAME}-keycloak-alb-sg" "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

log_info "ALB Security Group: $ALB_SG_ID"

# ALB inbound rules
aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region $REGION 2>&1 || log_warn "Port 80 rule already exists"

aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID \
    --protocol tcp --port 443 --cidr 0.0.0.0/0 \
    --region $REGION 2>&1 || log_warn "Port 443 rule already exists"

step "Creating Keycloak ECS Security Group"
ECS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-keycloak-ecs-sg" \
    --description "Security group for Keycloak ECS tasks" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --output text --query 'GroupId' 2>&1 || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT_NAME}-keycloak-ecs-sg" "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

log_info "ECS Security Group: $ECS_SG_ID"

# ECS inbound rules
aws ec2 authorize-security-group-ingress \
    --group-id $ECS_SG_ID \
    --protocol tcp --port 8080 --source-group $ALB_SG_ID \
    --region $REGION 2>&1 || log_warn "Port 8080 from ALB rule already exists"

step "Creating RDS Security Group"
RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-keycloak-rds-sg" \
    --description "Security group for Keycloak RDS databases" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --output text --query 'GroupId' 2>&1 || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT_NAME}-keycloak-rds-sg" "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

log_info "RDS Security Group: $RDS_SG_ID"

# RDS inbound rules
aws ec2 authorize-security-group-ingress \
    --group-id $RDS_SG_ID \
    --protocol tcp --port 5432 --source-group $ECS_SG_ID \
    --region $REGION 2>&1 || log_warn "Port 5432 from ECS rule already exists"

step "Creating OpenData RDS Security Group"
OPENDATA_RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-opendata-rds-sg" \
    --description "Security group for OpenData RDS database" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --output text --query 'GroupId' 2>&1 || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT_NAME}-opendata-rds-sg" "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

log_info "OpenData RDS Security Group: $OPENDATA_RDS_SG_ID"

# Allow Denodo EC2 to access OpenData RDS
DENODO_EC2_IP="10.0.75.195"
aws ec2 authorize-security-group-ingress \
    --group-id $OPENDATA_RDS_SG_ID \
    --protocol tcp --port 5432 --cidr "${DENODO_EC2_IP}/32" \
    --region $REGION 2>&1 || log_warn "Denodo access rule already exists"

# Allow ECS tasks to access OpenData RDS (for data loading)
aws ec2 authorize-security-group-ingress \
    --group-id $OPENDATA_RDS_SG_ID \
    --protocol tcp --port 5432 --source-group $ECS_SG_ID \
    --region $REGION 2>&1 || log_warn "ECS access to OpenData RDS already exists"

step "Updating Denodo EC2 security group"
# Find Denodo EC2 instance
DENODO_INSTANCE_ID="i-0aef555dcb0ff873f"
DENODO_SG=$(aws ec2 describe-instances \
    --instance-ids $DENODO_INSTANCE_ID \
    --region $REGION \
    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
    --output text 2>&1 || echo "")

if [ ! -z "$DENODO_SG" ] && [ "$DENODO_SG" != "None" ]; then
    log_info "Denodo Security Group: $DENODO_SG"
    # Allow Denodo to access Keycloak
    aws ec2 authorize-security-group-ingress \
        --group-id $ECS_SG_ID \
        --protocol tcp --port 8080 --source-group $DENODO_SG \
        --region $REGION 2>&1 || log_warn "Denodo to Keycloak rule already exists"
fi

###############################################################################
# PHASE 2: Secrets Manager
###############################################################################

log_section "PHASE 2: CREATING SECRETS"

step "Generating secure passwords"
KEYCLOAK_PROVIDER_DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
KEYCLOAK_CONSUMER_DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
OPENDATA_DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
CLIENT_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
API_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

step "Creating Keycloak Provider DB secret"
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/keycloak/provider/db" \
    --description "Keycloak Provider database credentials" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_PROVIDER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_provider\"}" \
    --region $REGION 2>&1 || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/provider/db" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_PROVIDER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_provider\"}" \
    --region $REGION >/dev/null

log_info "Created secret: ${PROJECT_NAME}/keycloak/provider/db"

step "Creating Keycloak Consumer DB secret"
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/keycloak/consumer/db" \
    --description "Keycloak Consumer database credentials" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_CONSUMER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_consumer\"}" \
    --region $REGION 2>&1 || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/consumer/db" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_CONSUMER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_consumer\"}" \
    --region $REGION >/dev/null

log_info "Created secret: ${PROJECT_NAME}/keycloak/consumer/db"

step "Creating OpenData DB secret"
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/opendata/db" \
    --description "OpenData database credentials" \
    --secret-string "{\"username\":\"denodo\",\"password\":\"$OPENDATA_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"opendata\"}" \
    --region $REGION 2>&1 || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/opendata/db" \
    --secret-string "{\"username\":\"denodo\",\"password\":\"$OPENDATA_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"opendata\"}" \
    --region $REGION >/dev/null

log_info "Created secret: ${PROJECT_NAME}/opendata/db"

step "Creating Keycloak admin secret"
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/keycloak/admin" \
    --description "Keycloak admin credentials" \
    --secret-string "{\"username\":\"admin\",\"password\":\"$KEYCLOAK_ADMIN_PASSWORD\"}" \
    --region $REGION 2>&1 || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/admin" \
    --secret-string "{\"username\":\"admin\",\"password\":\"$KEYCLOAK_ADMIN_PASSWORD\"}" \
    --region $REGION >/dev/null

log_info "Created secret: ${PROJECT_NAME}/keycloak/admin"

step "Creating OIDC client secret"
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/keycloak/client-secret" \
    --description "OIDC client secret for federation" \
    --secret-string "{\"clientId\":\"denodo-consumer\",\"clientSecret\":\"$CLIENT_SECRET\"}" \
    --region $REGION 2>&1 || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/client-secret" \
    --secret-string "{\"clientId\":\"denodo-consumer\",\"clientSecret\":\"$CLIENT_SECRET\"}" \
    --region $REGION >/dev/null

log_info "Created secret: ${PROJECT_NAME}/keycloak/client-secret"

step "Creating API Gateway key secret"
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/api/auth-key" \
    --description "API Gateway authorization key" \
    --secret-string "{\"apiKey\":\"$API_KEY\"}" \
    --region $REGION 2>&1 || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/api/auth-key" \
    --secret-string "{\"apiKey\":\"$API_KEY\"}" \
    --region $REGION >/dev/null

log_info "Created secret: ${PROJECT_NAME}/api/auth-key"

###############################################################################
# PHASE 3: RDS Databases
###############################################################################

log_section "PHASE 3: CREATING RDS DATABASES"

step "Creating DB subnet group"
DB_SUBNET_GROUP_NAME="${PROJECT_NAME}-db-subnet-group"
aws rds create-db-subnet-group \
    --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
    --db-subnet-group-description "Subnet group for Denodo POC databases" \
    --subnet-ids $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2 \
    --region $REGION 2>&1 || log_warn "DB subnet group already exists"

log_info "DB Subnet Group: $DB_SUBNET_GROUP_NAME"

step "Creating Keycloak Provider RDS instance"
PROVIDER_DB_ID="${PROJECT_NAME}-keycloak-provider-db"
aws rds create-db-instance \
    --db-instance-identifier $PROVIDER_DB_ID \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --engine-version 15 \
    --master-username keycloak \
    --master-user-password "$KEYCLOAK_PROVIDER_DB_PASSWORD" \
    --allocated-storage 20 \
    --storage-type gp3 \
    --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
    --vpc-security-group-ids $RDS_SG_ID \
    --backup-retention-period 7 \
    --no-publicly-accessible \
    --tags "Key=Project,Value=$PROJECT_NAME" "Key=Component,Value=keycloak-provider" \
    --region $REGION 2>&1 || log_warn "Keycloak Provider DB already exists"

log_info "Creating RDS instance: $PROVIDER_DB_ID (this may take 5-10 minutes)"

step "Creating Keycloak Consumer RDS instance"
CONSUMER_DB_ID="${PROJECT_NAME}-keycloak-consumer-db"
aws rds create-db-instance \
    --db-instance-identifier $CONSUMER_DB_ID \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --engine-version 15 \
    --master-username keycloak \
    --master-user-password "$KEYCLOAK_CONSUMER_DB_PASSWORD" \
    --allocated-storage 20 \
    --storage-type gp3 \
    --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
    --vpc-security-group-ids $RDS_SG_ID \
    --backup-retention-period 7 \
    --no-publicly-accessible \
    --tags "Key=Project,Value=$PROJECT_NAME" "Key=Component,Value=keycloak-consumer" \
    --region $REGION 2>&1 || log_warn "Keycloak Consumer DB already exists"

log_info "Creating RDS instance: $CONSUMER_DB_ID (this may take 5-10 minutes)"

step "Creating OpenData RDS instance"
OPENDATA_DB_ID="${PROJECT_NAME}-opendata-db"
aws rds create-db-instance \
    --db-instance-identifier $OPENDATA_DB_ID \
    --db-instance-class db.t3.small \
    --engine postgres \
    --engine-version 15 \
    --master-username denodo \
    --master-user-password "$OPENDATA_DB_PASSWORD" \
    --allocated-storage 50 \
    --storage-type gp3 \
    --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
    --vpc-security-group-ids $OPENDATA_RDS_SG_ID \
    --backup-retention-period 7 \
    --no-publicly-accessible \
    --tags "Key=Project,Value=$PROJECT_NAME" "Key=Component,Value=opendata" \
    --region $REGION 2>&1 || log_warn "OpenData DB already exists"

log_info "Creating RDS instance: $OPENDATA_DB_ID (this may take 5-10 minutes)"

log_info "Waiting for RDS instances to be available..."
log_warn "This will take approximately 10-15 minutes. You can monitor progress in AWS Console."

# Wait for all RDS instances
aws rds wait db-instance-available --db-instance-identifier $PROVIDER_DB_ID --region $REGION &
aws rds wait db-instance-available --db-instance-identifier $CONSUMER_DB_ID --region $REGION &
aws rds wait db-instance-available --db-instance-identifier $OPENDATA_DB_ID --region $REGION &
wait

log_info "All RDS instances are now available"

# Get RDS endpoints
PROVIDER_DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier $PROVIDER_DB_ID \
    --region $REGION \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)

CONSUMER_DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier $CONSUMER_DB_ID \
    --region $REGION \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)

OPENDATA_DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier $OPENDATA_DB_ID \
    --region $REGION \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)

log_info "Provider DB Endpoint: $PROVIDER_DB_ENDPOINT"
log_info "Consumer DB Endpoint: $CONSUMER_DB_ENDPOINT"
log_info "OpenData DB Endpoint: $OPENDATA_DB_ENDPOINT"

# Update secrets with endpoints
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/provider/db" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_PROVIDER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_provider\",\"host\":\"$PROVIDER_DB_ENDPOINT\"}" \
    --region $REGION >/dev/null

aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/consumer/db" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_CONSUMER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_consumer\",\"host\":\"$CONSUMER_DB_ENDPOINT\"}" \
    --region $REGION >/dev/null

aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/opendata/db" \
    --secret-string "{\"username\":\"denodo\",\"password\":\"$OPENDATA_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"opendata\",\"host\":\"$OPENDATA_DB_ENDPOINT\"}" \
    --region $REGION >/dev/null

###############################################################################
# Save deployment info for next steps
###############################################################################

cat > deployment-info.json <<EOF
{
  "region": "$REGION",
  "vpcId": "$VPC_ID",
  "accountId": "$ACCOUNT_ID",
  "projectName": "$PROJECT_NAME",
  "ecsClusterName": "$ECS_CLUSTER_NAME",
  "securityGroups": {
    "alb": "$ALB_SG_ID",
    "ecs": "$ECS_SG_ID",
    "rds": "$RDS_SG_ID",
    "opendataRds": "$OPENDATA_RDS_SG_ID"
  },
  "subnets": {
    "private": ["$PRIVATE_SUBNET_1", "$PRIVATE_SUBNET_2"],
    "public": ["$PUBLIC_SUBNET_1", "$PUBLIC_SUBNET_2"]
  },
  "rdsEndpoints": {
    "provider": "$PROVIDER_DB_ENDPOINT",
    "consumer": "$CONSUMER_DB_ENDPOINT",
    "opendata": "$OPENDATA_DB_ENDPOINT"
  },
  "secrets": {
    "providerDb": "${PROJECT_NAME}/keycloak/provider/db",
    "consumerDb": "${PROJECT_NAME}/keycloak/consumer/db",
    "opendataDb": "${PROJECT_NAME}/opendata/db",
    "keycloakAdmin": "${PROJECT_NAME}/keycloak/admin",
    "clientSecret": "${PROJECT_NAME}/keycloak/client-secret",
    "apiKey": "${PROJECT_NAME}/api/auth-key"
  },
  "deploymentTimestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log_section "PHASE 3 COMPLETE - Infrastructure Created"
log_info "Deployment info saved to deployment-info.json"
log_info ""
log_info "Next steps:"
log_info "1. Run: ./scripts/deploy-ecs-keycloak.sh (to create ECS cluster and services)"
log_info "2. Run: ./scripts/load-opendata.sh (to populate OpenData database)"
log_info "3. Run: ./scripts/configure-keycloak.sh (to configure OIDC federation)"
log_info "4. Run: ./scripts/deploy-lambda-api.sh (to deploy authorization API)"
log_info ""
log_info "Or run: ./scripts/deploy-all.sh (to execute all steps automatically)"
log_warn ""
log_warn "Estimated remaining deployment time: 20-30 minutes"

echo ""
log_section "DEPLOYMENT SUMMARY"
echo ""
echo "Resources Created:"
echo "  ✓ 6 Security Groups"
echo "  ✓ 3 RDS PostgreSQL Instances"
echo "  ✓ 6 Secrets in Secrets Manager"
echo "  ✓ DB Subnet Group"
echo ""
echo "Ready for:"
echo "  → ECS Cluster and Keycloak services"
echo "  → OpenData loading"
echo "  → OIDC federation configuration"
echo "  → Lambda API deployment"
echo ""
echo "Total cost estimate: ~$130/month"
echo ""
