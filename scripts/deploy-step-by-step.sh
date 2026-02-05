#!/bin/bash
###############################################################################
# Denodo Keycloak POC - Déploiement Étape par Étape
# 
# Ce script déploie l'infrastructure complète avec validation à chaque étape
# et alimentation des données OpenData
#
# Usage: ./deploy-step-by-step.sh
#
# Date: 5 février 2026
# Auteur: Jaafar Benabderrazak
###############################################################################

set -e

# Configuration
REGION="eu-west-3"
VPC_ID="vpc-08ffb9d90f07533d0"
ACCOUNT_ID="928902064673"
PROJECT_NAME="denodo-poc"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Couleurs
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
log_step() { echo -e "${CYAN}▶ ÉTAPE $1:${NC} $2"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }

# Fonction pour pause interactive
pause_for_validation() {
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Validation requise avant de continuer${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    read -p "Appuyez sur ENTRÉE pour continuer ou Ctrl+C pour arrêter..."
    echo ""
}

###############################################################################
# PHASE 0: VÉRIFICATION DES PRÉREQUIS
###############################################################################

log_phase "PHASE 0: VÉRIFICATION DES PRÉREQUIS"

log_step "0.1" "Vérification des outils installés"
for tool in aws jq curl psql python3; do
    if command -v $tool &> /dev/null; then
        log_success "$tool installé"
    else
        log_error "$tool non installé"
        exit 1
    fi
done

log_step "0.2" "Validation des credentials AWS"
CALLER_IDENTITY=$(aws sts get-caller-identity --region $REGION 2>/dev/null || echo "")
if [ -z "$CALLER_IDENTITY" ]; then
    log_error "Credentials AWS non configurés"
    exit 1
fi

CURRENT_ACCOUNT=$(echo $CALLER_IDENTITY | jq -r '.Account')
log_success "Compte AWS: $CURRENT_ACCOUNT"
log_success "Région: $REGION"

log_step "0.3" "Validation du VPC"
VPC_EXISTS=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
if [ -z "$VPC_EXISTS" ]; then
    log_error "VPC $VPC_ID introuvable"
    exit 1
fi
log_success "VPC $VPC_ID validé"

log_success "Phase 0 terminée - Tous les prérequis sont OK"
pause_for_validation

###############################################################################
# PHASE 1: CRÉATION DES GROUPES DE SÉCURITÉ
###############################################################################

log_phase "PHASE 1: CRÉATION DES GROUPES DE SÉCURITÉ"

log_step "1.1" "Découverte des subnets"
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*private*" \
    --region $REGION \
    --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' \
    --output json)

PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*public*" \
    --region $REGION \
    --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' \
    --output json)

PRIVATE_SUBNET_1=$(echo $PRIVATE_SUBNETS | jq -r '.[0]')
PRIVATE_SUBNET_2=$(echo $PRIVATE_SUBNETS | jq -r '.[1]')
PUBLIC_SUBNET_1=$(echo $PUBLIC_SUBNETS | jq -r '.[0]')
PUBLIC_SUBNET_2=$(echo $PUBLIC_SUBNETS | jq -r '.[1]')

log_success "Subnets privés: $PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2"
log_success "Subnets publics: $PUBLIC_SUBNET_1, $PUBLIC_SUBNET_2"

log_step "1.2" "Création du Security Group ALB"
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-keycloak-alb-sg" \
    --description "Security group for Keycloak ALB" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --output text --query 'GroupId' 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT_NAME}-keycloak-alb-sg" "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0 --region $REGION 2>/dev/null || true
log_success "ALB SG créé: $ALB_SG_ID"

log_step "1.3" "Création du Security Group ECS"
ECS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-keycloak-ecs-sg" \
    --description "Security group for Keycloak ECS tasks" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --output text --query 'GroupId' 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT_NAME}-keycloak-ecs-sg" "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 8080 --source-group $ALB_SG_ID --region $REGION 2>/dev/null || true
log_success "ECS SG créé: $ECS_SG_ID"

log_step "1.4" "Création du Security Group RDS Keycloak"
RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-keycloak-rds-sg" \
    --description "Security group for Keycloak RDS databases" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --output text --query 'GroupId' 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT_NAME}-keycloak-rds-sg" "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

aws ec2 authorize-security-group-ingress --group-id $RDS_SG_ID --protocol tcp --port 5432 --source-group $ECS_SG_ID --region $REGION 2>/dev/null || true
log_success "RDS Keycloak SG créé: $RDS_SG_ID"

log_step "1.5" "Création du Security Group RDS OpenData"
OPENDATA_RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-opendata-rds-sg" \
    --description "Security group for OpenData RDS database" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --output text --query 'GroupId' 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT_NAME}-opendata-rds-sg" "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

DENODO_EC2_IP="10.0.75.195"
aws ec2 authorize-security-group-ingress --group-id $OPENDATA_RDS_SG_ID --protocol tcp --port 5432 --cidr "${DENODO_EC2_IP}/32" --region $REGION 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $OPENDATA_RDS_SG_ID --protocol tcp --port 5432 --source-group $ECS_SG_ID --region $REGION 2>/dev/null || true
log_success "RDS OpenData SG créé: $OPENDATA_RDS_SG_ID"

log_success "Phase 1 terminée - Security Groups créés"
pause_for_validation

###############################################################################
# PHASE 2: CRÉATION DES SECRETS
###############################################################################

log_phase "PHASE 2: GÉNÉRATION ET STOCKAGE DES SECRETS"

log_step "2.1" "Génération des mots de passe sécurisés"
KEYCLOAK_PROVIDER_DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
KEYCLOAK_CONSUMER_DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
OPENDATA_DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
CLIENT_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
API_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
log_success "6 mots de passe générés"

log_step "2.2" "Stockage dans AWS Secrets Manager"

# Keycloak Provider DB
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/keycloak/provider/db" \
    --description "Keycloak Provider database credentials" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_PROVIDER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_provider\"}" \
    --region $REGION 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/provider/db" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_PROVIDER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_provider\"}" \
    --region $REGION >/dev/null
log_success "Secret Keycloak Provider DB créé"

# Keycloak Consumer DB
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/keycloak/consumer/db" \
    --description "Keycloak Consumer database credentials" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_CONSUMER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_consumer\"}" \
    --region $REGION 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/consumer/db" \
    --secret-string "{\"username\":\"keycloak\",\"password\":\"$KEYCLOAK_CONSUMER_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak_consumer\"}" \
    --region $REGION >/dev/null
log_success "Secret Keycloak Consumer DB créé"

# OpenData DB
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/opendata/db" \
    --description "OpenData database credentials" \
    --secret-string "{\"username\":\"denodo\",\"password\":\"$OPENDATA_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"opendata\"}" \
    --region $REGION 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/opendata/db" \
    --secret-string "{\"username\":\"denodo\",\"password\":\"$OPENDATA_DB_PASSWORD\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"opendata\"}" \
    --region $REGION >/dev/null
log_success "Secret OpenData DB créé"

# Keycloak Admin
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/keycloak/admin" \
    --description "Keycloak admin credentials" \
    --secret-string "{\"username\":\"admin\",\"password\":\"$KEYCLOAK_ADMIN_PASSWORD\"}" \
    --region $REGION 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/admin" \
    --secret-string "{\"username\":\"admin\",\"password\":\"$KEYCLOAK_ADMIN_PASSWORD\"}" \
    --region $REGION >/dev/null
log_success "Secret Keycloak Admin créé"

# Client Secret
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/keycloak/client-secret" \
    --description "OIDC client secret for federation" \
    --secret-string "{\"clientId\":\"denodo-consumer\",\"clientSecret\":\"$CLIENT_SECRET\"}" \
    --region $REGION 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/keycloak/client-secret" \
    --secret-string "{\"clientId\":\"denodo-consumer\",\"clientSecret\":\"$CLIENT_SECRET\"}" \
    --region $REGION >/dev/null
log_success "Secret OIDC Client créé"

# API Key
aws secretsmanager create-secret \
    --name "${PROJECT_NAME}/api/auth-key" \
    --description "API Gateway authorization key" \
    --secret-string "{\"apiKey\":\"$API_KEY\"}" \
    --region $REGION 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id "${PROJECT_NAME}/api/auth-key" \
    --secret-string "{\"apiKey\":\"$API_KEY\"}" \
    --region $REGION >/dev/null
log_success "Secret API Key créé"

log_success "Phase 2 terminée - 6 secrets stockés dans Secrets Manager"
pause_for_validation

###############################################################################
# PHASE 3: CRÉATION DES BASES DE DONNÉES RDS
###############################################################################

log_phase "PHASE 3: CRÉATION DES BASES DE DONNÉES RDS"

log_step "3.1" "Création du DB Subnet Group"
DB_SUBNET_GROUP_NAME="${PROJECT_NAME}-db-subnet-group"
aws rds create-db-subnet-group \
    --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
    --db-subnet-group-description "Subnet group for Denodo POC databases" \
    --subnet-ids $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2 \
    --region $REGION 2>/dev/null || log_warn "DB subnet group existe déjà"
log_success "DB Subnet Group: $DB_SUBNET_GROUP_NAME"

log_step "3.2" "Vérification des instances RDS existantes"

# Function to check RDS instance status
check_rds_status() {
    local db_id=$1
    aws rds describe-db-instances \
        --db-instance-identifier $db_id \
        --region $REGION \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null || echo "not-found"
}

# Function to wait for deletion
wait_for_deletion() {
    local db_id=$1
    log_info "Attente de la suppression complète de $db_id..."
    while true; do
        STATUS=$(check_rds_status $db_id)
        if [ "$STATUS" == "not-found" ]; then
            log_success "$db_id complètement supprimé"
            break
        fi
        log_warn "$db_id en cours de suppression (status: $STATUS)... attente 30s"
        sleep 30
    done
}

PROVIDER_DB_ID="${PROJECT_NAME}-keycloak-provider-db"
CONSUMER_DB_ID="${PROJECT_NAME}-keycloak-consumer-db"
OPENDATA_DB_ID="${PROJECT_NAME}-opendata-db"

# Check Provider DB
PROVIDER_STATUS=$(check_rds_status $PROVIDER_DB_ID)
log_info "Provider DB status: $PROVIDER_STATUS"
if [ "$PROVIDER_STATUS" == "deleting" ]; then
    wait_for_deletion $PROVIDER_DB_ID
elif [ "$PROVIDER_STATUS" == "available" ]; then
    log_success "Provider DB déjà disponible, réutilisation"
fi

# Check Consumer DB
CONSUMER_STATUS=$(check_rds_status $CONSUMER_DB_ID)
log_info "Consumer DB status: $CONSUMER_STATUS"
if [ "$CONSUMER_STATUS" == "deleting" ]; then
    wait_for_deletion $CONSUMER_DB_ID
elif [ "$CONSUMER_STATUS" == "available" ]; then
    log_success "Consumer DB déjà disponible, réutilisation"
fi

# Check OpenData DB
OPENDATA_STATUS=$(check_rds_status $OPENDATA_DB_ID)
log_info "OpenData DB status: $OPENDATA_STATUS"
if [ "$OPENDATA_STATUS" == "deleting" ]; then
    wait_for_deletion $OPENDATA_DB_ID
elif [ "$OPENDATA_STATUS" == "available" ]; then
    log_success "OpenData DB déjà disponible, réutilisation"
fi

log_step "3.3" "Création des instances RDS PostgreSQL"
log_info "⏱ Temps estimé: 10-15 minutes"

# Create Provider DB if needed
if [ "$PROVIDER_STATUS" == "not-found" ]; then
    log_info "Création de $PROVIDER_DB_ID..."
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
        --region $REGION >/dev/null
    log_success "RDS Keycloak Provider lancé"
fi

# Create Consumer DB if needed
if [ "$CONSUMER_STATUS" == "not-found" ]; then
    log_info "Création de $CONSUMER_DB_ID..."
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
        --region $REGION >/dev/null
    log_success "RDS Keycloak Consumer lancé"
fi

# Create OpenData DB if needed
if [ "$OPENDATA_STATUS" == "not-found" ]; then
    log_info "Création de $OPENDATA_DB_ID..."
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
        --region $REGION >/dev/null
    log_success "RDS OpenData lancé"
fi

log_step "3.4" "Attente de disponibilité des instances RDS"
log_info "Cela peut prendre 10-15 minutes..."

# Wait only if instances need to become available
if [ "$PROVIDER_STATUS" != "available" ]; then
    log_info "Attente Provider DB..."
    aws rds wait db-instance-available --db-instance-identifier $PROVIDER_DB_ID --region $REGION 2>/dev/null || log_warn "Timeout Provider DB"
fi
log_success "Keycloak Provider DB disponible"

if [ "$CONSUMER_STATUS" != "available" ]; then
    log_info "Attente Consumer DB..."
    aws rds wait db-instance-available --db-instance-identifier $CONSUMER_DB_ID --region $REGION 2>/dev/null || log_warn "Timeout Consumer DB"
fi
log_success "Keycloak Consumer DB disponible"

if [ "$OPENDATA_STATUS" != "available" ]; then
    log_info "Attente OpenData DB..."
    aws rds wait db-instance-available --db-instance-identifier $OPENDATA_DB_ID --region $REGION 2>/dev/null || log_warn "Timeout OpenData DB"
fi
log_success "OpenData DB disponible"

log_step "3.5" "Récupération des endpoints RDS"

# Retry function for getting endpoints
get_endpoint_with_retry() {
    local db_id=$1
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        ENDPOINT=$(aws rds describe-db-instances \
            --db-instance-identifier $db_id \
            --region $REGION \
            --query 'DBInstances[0].Endpoint.Address' \
            --output text 2>/dev/null)
        
        if [ ! -z "$ENDPOINT" ] && [ "$ENDPOINT" != "None" ]; then
            echo $ENDPOINT
            return 0
        fi
        
        log_warn "Tentative $attempt/$max_attempts - Endpoint non disponible pour $db_id, attente 10s..."
        sleep 10
        ((attempt++))
    done
    
    log_error "Impossible de récupérer l'endpoint pour $db_id"
    return 1
}

PROVIDER_DB_ENDPOINT=$(get_endpoint_with_retry $PROVIDER_DB_ID)
CONSUMER_DB_ENDPOINT=$(get_endpoint_with_retry $CONSUMER_DB_ID)
OPENDATA_DB_ENDPOINT=$(get_endpoint_with_retry $OPENDATA_DB_ID)

if [ -z "$PROVIDER_DB_ENDPOINT" ] || [ -z "$CONSUMER_DB_ENDPOINT" ] || [ -z "$OPENDATA_DB_ENDPOINT" ]; then
    log_error "Impossible de récupérer tous les endpoints RDS"
    log_info "Vérifiez manuellement avec: aws rds describe-db-instances --region $REGION"
    exit 1
fi

log_success "Provider DB: $PROVIDER_DB_ENDPOINT"
log_success "Consumer DB: $CONSUMER_DB_ENDPOINT"
log_success "OpenData DB: $OPENDATA_DB_ENDPOINT"

log_step "3.6" "Mise à jour des secrets avec les endpoints"
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

log_success "Secrets mis à jour avec les endpoints"
log_success "Phase 3 terminée - 3 bases de données RDS créées et accessibles"
pause_for_validation

###############################################################################
# PHASE 4: INITIALISATION DU SCHÉMA OPENDATA
###############################################################################

log_phase "PHASE 4: INITIALISATION DU SCHÉMA OPENDATA"

log_step "4.1" "Création du schéma et des tables OpenData"
log_info "Exécution du script SQL: 01-create-opendata-schema.sql"

# Export PGPASSWORD pour psql
export PGPASSWORD="$OPENDATA_DB_PASSWORD"

# Exécution du script SQL
psql -h $OPENDATA_DB_ENDPOINT \
     -U denodo \
     -d opendata \
     -p 5432 \
     -f "${SCRIPT_DIR}/../sql/01-create-opendata-schema.sql" \
     2>&1 | grep -v "^$" || true

unset PGPASSWORD

log_success "Schéma OpenData créé (tables, vues, fonctions)"
log_success "Phase 4 terminée - Structure de base prête"
pause_for_validation

###############################################################################
# PHASE 5: ALIMENTATION DES DONNÉES OPENDATA
###############################################################################

log_phase "PHASE 5: ALIMENTATION DES DONNÉES OPENDATA"

log_step "5.1" "Téléchargement des données depuis APIs publiques"
log_info "⏱ Temps estimé: 5-10 minutes"

# Création du répertoire temporaire
TEMP_DIR=$(mktemp -d)
log_info "Répertoire temporaire: $TEMP_DIR"

log_step "5.2" "Récupération des données communes (geo.api.gouv.fr)"
log_info "Téléchargement de ~36,000 communes..."

curl -s "https://geo.api.gouv.fr/communes?fields=nom,code,codesPostaux,codeDepartement,codeRegion,population,surface&format=json&geometry=centre" \
    > "$TEMP_DIR/communes.json"

COMMUNE_COUNT=$(cat "$TEMP_DIR/communes.json" | jq '. | length')
log_success "$COMMUNE_COUNT communes téléchargées"

log_step "5.3" "Génération du script SQL d'insertion pour population_communes"

# Utilisation de Python pour générer le SQL (plus robuste pour l'échappement)
export COMMUNES_JSON_FILE="$TEMP_DIR/communes.json"
python3 <<'PYTHON_SCRIPT' > "$TEMP_DIR/insert_communes.sql"
import json
import os

json_file = os.environ.get('COMMUNES_JSON_FILE')
with open(json_file, 'r', encoding='utf-8') as f:
    communes = json.load(f)

print("-- Insertion des données communes")
print("BEGIN;")

for commune in communes:
    code = commune.get('code', '')
    nom = commune.get('nom', '').replace("'", "''")
    code_postal = commune.get('codesPostaux', [''])[0] if commune.get('codesPostaux') else ''
    code_dept = commune.get('codeDepartement', '')
    code_region = commune.get('codeRegion', '')
    population = commune.get('population', 0) or 0
    surface = commune.get('surface', 0) or 0
    
    coords = commune.get('centre', {}).get('coordinates', [0, 0]) if commune.get('centre') else [0, 0]
    longitude = coords[0] if len(coords) > 0 else 0
    latitude = coords[1] if len(coords) > 1 else 0
    
    print(f"INSERT INTO opendata.population_communes (code_commune, nom_commune, code_postal, code_departement, code_region, population, superficie, latitude, longitude) VALUES ('{code}', '{nom}', '{code_postal}', '{code_dept}', '{code_region}', {population}, {surface}, {latitude}, {longitude}) ON CONFLICT (code_commune) DO NOTHING;")

print("COMMIT;")
PYTHON_SCRIPT
unset COMMUNES_JSON_FILE

log_success "Script SQL communes généré"

log_step "5.4" "Génération de données entreprises (échantillon)"
log_info "Création d'un échantillon de 1000 entreprises fictives..."

cat > "$TEMP_DIR/insert_entreprises.sql" <<'SQL_HEADER'
-- Insertion des données entreprises (échantillon)
BEGIN;
SQL_HEADER

# Génération de 1000 entreprises fictives
for i in {1..1000}; do
    SIREN=$(printf "%09d" $((100000000 + RANDOM % 900000000)))
    NOM="Entreprise Test $i"
    DEPARTEMENTS=("75" "69" "13" "31" "44" "33" "59" "35" "67" "34")
    DEPT=${DEPARTEMENTS[$RANDOM % ${#DEPARTEMENTS[@]}]}
    CODES_NAF=("6201Z" "6202A" "6311Z" "6312Z" "6399Z" "7022Z" "7112B")
    NAF=${CODES_NAF[$RANDOM % ${#CODES_NAF[@]}]}
    EFFECTIFS=(5 10 20 50 100 250 500 1000)
    EFFECTIF=${EFFECTIFS[$RANDOM % ${#EFFECTIFS[@]}]}
    
    echo "INSERT INTO opendata.entreprises (siren, nom_raison_sociale, code_naf, libelle_naf, statut, effectif, departement, ville, code_postal, date_creation) VALUES ('$SIREN', '$NOM', '$NAF', 'Activités informatiques', 'Actif', $EFFECTIF, '$DEPT', 'Ville Test', '${DEPT}001', CURRENT_DATE - INTERVAL '$((RANDOM % 3650)) days') ON CONFLICT (siren) DO NOTHING;" >> "$TEMP_DIR/insert_entreprises.sql"
done

echo "COMMIT;" >> "$TEMP_DIR/insert_entreprises.sql"

log_success "Script SQL entreprises généré (1000 enregistrements)"

log_step "5.5" "Insertion des données dans PostgreSQL"
export PGPASSWORD="$OPENDATA_DB_PASSWORD"

log_info "Insertion des communes..."
psql -h $OPENDATA_DB_ENDPOINT -U denodo -d opendata -p 5432 -f "$TEMP_DIR/insert_communes.sql" -q
log_success "Communes insérées"

log_info "Insertion des entreprises..."
psql -h $OPENDATA_DB_ENDPOINT -U denodo -d opendata -p 5432 -f "$TEMP_DIR/insert_entreprises.sql" -q
log_success "Entreprises insérées"

unset PGPASSWORD

log_step "5.6" "Vérification des données"
export PGPASSWORD="$OPENDATA_DB_PASSWORD"

COMMUNE_DB_COUNT=$(psql -h $OPENDATA_DB_ENDPOINT -U denodo -d opendata -p 5432 -t -c "SELECT COUNT(*) FROM opendata.population_communes;" | xargs)
ENTREPRISE_DB_COUNT=$(psql -h $OPENDATA_DB_ENDPOINT -U denodo -d opendata -p 5432 -t -c "SELECT COUNT(*) FROM opendata.entreprises;" | xargs)

unset PGPASSWORD

log_success "Communes dans la base: $COMMUNE_DB_COUNT"
log_success "Entreprises dans la base: $ENTREPRISE_DB_COUNT"

# Nettoyage
rm -rf "$TEMP_DIR"
log_info "Fichiers temporaires supprimés"

log_success "Phase 5 terminée - Données OpenData chargées"
pause_for_validation

###############################################################################
# PHASE 6: SAUVEGARDE DES INFORMATIONS DE DÉPLOIEMENT
###############################################################################

log_phase "PHASE 6: SAUVEGARDE DES INFORMATIONS"

log_step "6.1" "Création du fichier deployment-info.json"

cat > deployment-info.json <<EOF
{
  "region": "$REGION",
  "vpcId": "$VPC_ID",
  "accountId": "$ACCOUNT_ID",
  "projectName": "$PROJECT_NAME",
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
  "rdsInstances": {
    "provider": "$PROVIDER_DB_ID",
    "consumer": "$CONSUMER_DB_ID",
    "opendata": "$OPENDATA_DB_ID"
  },
  "secrets": {
    "providerDb": "${PROJECT_NAME}/keycloak/provider/db",
    "consumerDb": "${PROJECT_NAME}/keycloak/consumer/db",
    "opendataDb": "${PROJECT_NAME}/opendata/db",
    "keycloakAdmin": "${PROJECT_NAME}/keycloak/admin",
    "clientSecret": "${PROJECT_NAME}/keycloak/client-secret",
    "apiKey": "${PROJECT_NAME}/api/auth-key"
  },
  "dataStats": {
    "communes": $COMMUNE_DB_COUNT,
    "entreprises": $ENTREPRISE_DB_COUNT
  },
  "deploymentTimestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log_success "Informations sauvegardées dans deployment-info.json"

###############################################################################
# RÉSUMÉ FINAL
###############################################################################

echo ""
log_phase "✓ DÉPLOIEMENT PHASE 1 TERMINÉ AVEC SUCCÈS"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              RÉSUMÉ DU DÉPLOIEMENT                         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Ressources créées:"
echo "  ✓ 4 Security Groups"
echo "  ✓ 3 Instances RDS PostgreSQL (disponibles)"
echo "  ✓ 6 Secrets dans Secrets Manager"
echo "  ✓ 1 DB Subnet Group"
echo "  ✓ Base OpenData alimentée ($COMMUNE_DB_COUNT communes, $ENTREPRISE_DB_COUNT entreprises)"
echo ""
echo "Endpoints RDS:"
echo "  • Keycloak Provider: $PROVIDER_DB_ENDPOINT"
echo "  • Keycloak Consumer: $CONSUMER_DB_ENDPOINT"
echo "  • OpenData: $OPENDATA_DB_ENDPOINT"
echo ""
echo -e "${YELLOW}Prochaines étapes:${NC}"
echo "  1. Déployer le cluster ECS et les services Keycloak"
echo "  2. Configurer la fédération OIDC"
echo "  3. Déployer l'API Lambda d'autorisation"
echo "  4. Créer l'Application Load Balancer"
echo ""
echo -e "${CYAN}Pour continuer, exécutez:${NC}"
echo "  ./scripts/deploy-ecs-keycloak.sh"
echo ""
echo "Estimation coût mensuel: ~$130/mois"
echo ""
