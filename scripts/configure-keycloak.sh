#!/bin/bash
###############################################################################
# Denodo Keycloak POC - Keycloak OIDC Federation Configuration
#
# Configures Keycloak realms, clients, identity providers, users, and
# claim mappers using the Keycloak Admin REST API.
#
# Prerequisites:
# - Keycloak services must be running (deploy-ecs-keycloak.sh completed)
# - ALB must be accessible
# - deployment-info.json must exist with ALB DNS
#
# Usage: ./scripts/configure-keycloak.sh
#
# Date: February 2026
# Author: Jaafar Benabderrazak
###############################################################################

set -e
trap 'echo -e "\033[0;31m[FATAL] Script failed at line $LINENO. Command: $BASH_COMMAND\033[0m"' ERR

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
log_step() { echo -e "${CYAN}▶ STEP $1:${NC} $2"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }

###############################################################################
# PHASE 0: Read deployment info & authenticate
###############################################################################

log_phase "PHASE 0: INITIALIZATION"

if [ ! -f "$DEPLOYMENT_INFO" ]; then
    log_error "deployment-info.json not found."
    exit 1
fi

REGION=$(jq -r '.region' "$DEPLOYMENT_INFO")
PROJECT_NAME=$(jq -r '.projectName' "$DEPLOYMENT_INFO")
ALB_DNS=$(jq -r '.alb.dns // empty' "$DEPLOYMENT_INFO")

if [ -z "$ALB_DNS" ]; then
    log_error "ALB DNS not found in deployment-info.json. Run deploy-ecs-keycloak.sh first."
    exit 1
fi

KC_BASE_URL="http://${ALB_DNS}"

# Get admin password from Secrets Manager
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
    --secret-id "${PROJECT_NAME}/keycloak/admin" \
    --region "$REGION" \
    --query SecretString --output text | jq -r '.password')

# Get OIDC client secret from Secrets Manager
CLIENT_SECRET=$(aws secretsmanager get-secret-value \
    --secret-id "${PROJECT_NAME}/keycloak/client-secret" \
    --region "$REGION" \
    --query SecretString --output text | jq -r '.clientSecret')

log_success "ALB URL: $KC_BASE_URL"

# Function to get admin token for a given realm
get_admin_token() {
    local realm=${1:-master}
    local response
    response=$(curl -s -X POST "${KC_BASE_URL}/auth/realms/${realm}/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=admin" \
        -d "password=${ADMIN_PASSWORD}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli")
    echo "$response" | jq -r '.access_token'
}

# Function to make authenticated API calls
kc_api() {
    local method=$1
    local path=$2
    local data=$3
    local token=$4

    if [ -z "$data" ]; then
        curl -s -X "$method" "${KC_BASE_URL}${path}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json"
    else
        curl -s -X "$method" "${KC_BASE_URL}${path}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$data"
    fi
}

log_step "0.1" "Testing Keycloak accessibility"

HEALTH_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "${KC_BASE_URL}/auth/health/ready" 2>/dev/null || echo "000")

if [ "$HEALTH_CHECK" != "200" ]; then
    log_error "Keycloak is not accessible at ${KC_BASE_URL} (HTTP $HEALTH_CHECK)"
    log_error "Ensure ECS services are running and ALB health checks pass."
    log_info "Check with: aws ecs describe-services --cluster denodo-keycloak-cluster --services keycloak-provider --region $REGION"
    exit 1
fi

log_success "Keycloak is healthy"

log_step "0.2" "Obtaining admin token"
ADMIN_TOKEN=$(get_admin_token)
if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" == "null" ]; then
    log_error "Failed to obtain admin token. Check admin credentials."
    exit 1
fi
log_success "Admin token obtained"

###############################################################################
# PHASE 1: Configure Provider Realm (denodo-idp)
###############################################################################

log_phase "PHASE 1: CONFIGURING PROVIDER REALM (denodo-idp)"

log_step "1.1" "Creating realm denodo-idp"

kc_api POST "/auth/admin/realms" '{
  "realm": "denodo-idp",
  "displayName": "Denodo Identity Provider",
  "enabled": true,
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": true,
  "editUsernameAllowed": false,
  "bruteForceProtected": true,
  "sslRequired": "none",
  "accessTokenLifespan": 300,
  "ssoSessionIdleTimeout": 1800,
  "ssoSessionMaxLifespan": 36000
}' "$ADMIN_TOKEN" > /dev/null 2>&1 || log_warn "Realm denodo-idp may already exist"

log_success "Realm denodo-idp created"

log_step "1.2" "Creating OIDC client 'denodo-consumer' on Provider"

kc_api POST "/auth/admin/realms/denodo-idp/clients" "{
  \"clientId\": \"denodo-consumer\",
  \"name\": \"Denodo Consumer Client\",
  \"protocol\": \"openid-connect\",
  \"publicClient\": false,
  \"secret\": \"${CLIENT_SECRET}\",
  \"directAccessGrantsEnabled\": true,
  \"standardFlowEnabled\": true,
  \"redirectUris\": [
    \"${KC_BASE_URL}/auth/realms/denodo-consumer/broker/provider-idp/endpoint\",
    \"${KC_BASE_URL}/auth/realms/denodo-consumer/broker/provider-idp/endpoint/*\"
  ],
  \"webOrigins\": [\"*\"],
  \"attributes\": {
    \"access.token.lifespan\": \"300\"
  }
}" "$ADMIN_TOKEN" > /dev/null 2>&1 || log_warn "Client denodo-consumer may already exist"

log_success "Client 'denodo-consumer' created on Provider"

log_step "1.3" "Creating custom protocol mappers for profiles/roles claims"

# Get the client UUID
PROVIDER_TOKEN=$(get_admin_token)
CLIENT_UUID=$(kc_api GET "/auth/admin/realms/denodo-idp/clients?clientId=denodo-consumer" "" "$PROVIDER_TOKEN" | jq -r '.[0].id')

if [ ! -z "$CLIENT_UUID" ] && [ "$CLIENT_UUID" != "null" ]; then
    # Mapper: profiles claim
    kc_api POST "/auth/admin/realms/denodo-idp/clients/${CLIENT_UUID}/protocol-mappers/models" '{
      "name": "profiles",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "config": {
        "user.attribute": "profiles",
        "claim.name": "profiles",
        "jsonType.label": "String",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "multivalued": "true"
      }
    }' "$PROVIDER_TOKEN" > /dev/null 2>&1 || log_warn "Profiles mapper may already exist"

    # Mapper: datasources claim
    kc_api POST "/auth/admin/realms/denodo-idp/clients/${CLIENT_UUID}/protocol-mappers/models" '{
      "name": "datasources",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "config": {
        "user.attribute": "datasources",
        "claim.name": "datasources",
        "jsonType.label": "String",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "multivalued": "true"
      }
    }' "$PROVIDER_TOKEN" > /dev/null 2>&1 || log_warn "Datasources mapper may already exist"

    # Mapper: department claim
    kc_api POST "/auth/admin/realms/denodo-idp/clients/${CLIENT_UUID}/protocol-mappers/models" '{
      "name": "department",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "config": {
        "user.attribute": "department",
        "claim.name": "department",
        "jsonType.label": "String",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true"
      }
    }' "$PROVIDER_TOKEN" > /dev/null 2>&1 || log_warn "Department mapper may already exist"

    log_success "Custom claim mappers created"
else
    log_warn "Could not find client UUID, skipping mappers"
fi

###############################################################################
# PHASE 2: Create Test Users on Provider
###############################################################################

log_phase "PHASE 2: CREATING TEST USERS ON PROVIDER"

PROVIDER_TOKEN=$(get_admin_token)

create_user() {
    local username=$1
    local email=$2
    local password=$3
    local first_name=$4
    local last_name=$5
    local profiles=$6
    local datasources=$7
    local department=$8

    log_step "2.x" "Creating user: $email"

    kc_api POST "/auth/admin/realms/denodo-idp/users" "{
      \"username\": \"${email}\",
      \"email\": \"${email}\",
      \"emailVerified\": true,
      \"enabled\": true,
      \"firstName\": \"${first_name}\",
      \"lastName\": \"${last_name}\",
      \"credentials\": [{
        \"type\": \"password\",
        \"value\": \"${password}\",
        \"temporary\": false
      }],
      \"attributes\": {
        \"profiles\": [\"${profiles}\"],
        \"datasources\": [\"${datasources}\"],
        \"department\": [\"${department}\"]
      }
    }" "$PROVIDER_TOKEN" > /dev/null 2>&1 || log_warn "User $email may already exist"

    log_success "User $email created"
}

create_user "analyst" "analyst@denodo.com" "Analyst@2026!" \
    "Data" "Analyst" "data-analyst" "rds-opendata,api-geo" "Analytics"

create_user "scientist" "scientist@denodo.com" "Scientist@2026!" \
    "Data" "Scientist" "data-scientist" "rds-opendata,api-geo,api-sirene" "Research"

create_user "admin_user" "admin@denodo.com" "Admin@2026!" \
    "System" "Administrator" "admin" "*" "IT"

log_success "All test users created"

###############################################################################
# PHASE 3: Configure Consumer Realm (denodo-consumer)
###############################################################################

log_phase "PHASE 3: CONFIGURING CONSUMER REALM (denodo-consumer)"

ADMIN_TOKEN=$(get_admin_token)

log_step "3.1" "Creating realm denodo-consumer"

kc_api POST "/auth/admin/realms" '{
  "realm": "denodo-consumer",
  "displayName": "Denodo Service Provider",
  "enabled": true,
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "sslRequired": "none",
  "accessTokenLifespan": 300,
  "ssoSessionIdleTimeout": 1800,
  "ssoSessionMaxLifespan": 36000
}' "$ADMIN_TOKEN" > /dev/null 2>&1 || log_warn "Realm denodo-consumer may already exist"

log_success "Realm denodo-consumer created"

log_step "3.2" "Configuring OIDC Identity Provider federation"

ADMIN_TOKEN=$(get_admin_token)

kc_api POST "/auth/admin/realms/denodo-consumer/identity-provider/instances" "{
  \"alias\": \"provider-idp\",
  \"displayName\": \"Denodo Identity Provider\",
  \"providerId\": \"oidc\",
  \"enabled\": true,
  \"trustEmail\": true,
  \"storeToken\": true,
  \"firstBrokerLoginFlowAlias\": \"first broker login\",
  \"config\": {
    \"authorizationUrl\": \"${KC_BASE_URL}/auth/realms/denodo-idp/protocol/openid-connect/auth\",
    \"tokenUrl\": \"${KC_BASE_URL}/auth/realms/denodo-idp/protocol/openid-connect/token\",
    \"userInfoUrl\": \"${KC_BASE_URL}/auth/realms/denodo-idp/protocol/openid-connect/userinfo\",
    \"logoutUrl\": \"${KC_BASE_URL}/auth/realms/denodo-idp/protocol/openid-connect/logout\",
    \"issuer\": \"${KC_BASE_URL}/auth/realms/denodo-idp\",
    \"clientId\": \"denodo-consumer\",
    \"clientSecret\": \"${CLIENT_SECRET}\",
    \"defaultScope\": \"openid profile email\",
    \"syncMode\": \"IMPORT\",
    \"validateSignature\": \"true\",
    \"useJwksUrl\": \"true\",
    \"jwksUrl\": \"${KC_BASE_URL}/auth/realms/denodo-idp/protocol/openid-connect/certs\"
  }
}" "$ADMIN_TOKEN" > /dev/null 2>&1 || log_warn "Identity Provider may already exist"

log_success "OIDC federation configured (Consumer → Provider)"

log_step "3.3" "Creating Denodo client on Consumer realm"

kc_api POST "/auth/admin/realms/denodo-consumer/clients" "{
  \"clientId\": \"denodo-data-catalog\",
  \"name\": \"Denodo Data Catalog\",
  \"protocol\": \"openid-connect\",
  \"publicClient\": false,
  \"directAccessGrantsEnabled\": true,
  \"standardFlowEnabled\": true,
  \"redirectUris\": [
    \"https://10.0.75.195:9443/*\",
    \"http://10.0.75.195:9090/*\"
  ],
  \"webOrigins\": [\"*\"]
}" "$ADMIN_TOKEN" > /dev/null 2>&1 || log_warn "Denodo client may already exist"

log_success "Denodo client created on Consumer realm"

log_step "3.4" "Configuring identity provider claim mappers on Consumer"

ADMIN_TOKEN=$(get_admin_token)

# Map profiles claim from Provider
kc_api POST "/auth/admin/realms/denodo-consumer/identity-provider/instances/provider-idp/mappers" '{
  "name": "profiles-mapper",
  "identityProviderAlias": "provider-idp",
  "identityProviderMapper": "oidc-user-attribute-idp-mapper",
  "config": {
    "syncMode": "INHERIT",
    "claim": "profiles",
    "user.attribute": "profiles"
  }
}' "$ADMIN_TOKEN" > /dev/null 2>&1 || log_warn "Profiles mapper may already exist"

# Map datasources claim
kc_api POST "/auth/admin/realms/denodo-consumer/identity-provider/instances/provider-idp/mappers" '{
  "name": "datasources-mapper",
  "identityProviderAlias": "provider-idp",
  "identityProviderMapper": "oidc-user-attribute-idp-mapper",
  "config": {
    "syncMode": "INHERIT",
    "claim": "datasources",
    "user.attribute": "datasources"
  }
}' "$ADMIN_TOKEN" > /dev/null 2>&1 || log_warn "Datasources mapper may already exist"

# Map department claim
kc_api POST "/auth/admin/realms/denodo-consumer/identity-provider/instances/provider-idp/mappers" '{
  "name": "department-mapper",
  "identityProviderAlias": "provider-idp",
  "identityProviderMapper": "oidc-user-attribute-idp-mapper",
  "config": {
    "syncMode": "INHERIT",
    "claim": "department",
    "user.attribute": "department"
  }
}' "$ADMIN_TOKEN" > /dev/null 2>&1 || log_warn "Department mapper may already exist"

log_success "Identity provider claim mappers configured"

###############################################################################
# SUMMARY
###############################################################################

echo ""
log_phase "✓ KEYCLOAK OIDC FEDERATION CONFIGURED"
echo ""
echo "Configuration Summary:"
echo "  ✓ Provider Realm: denodo-idp"
echo "    • Client: denodo-consumer (OIDC)"
echo "    • Claim mappers: profiles, datasources, department"
echo "    • Users: analyst@denodo.com, scientist@denodo.com, admin@denodo.com"
echo ""
echo "  ✓ Consumer Realm: denodo-consumer"
echo "    • Identity Provider: provider-idp (federated with denodo-idp)"
echo "    • Client: denodo-data-catalog (for Denodo integration)"
echo "    • IDP Claim mappers: profiles, datasources, department"
echo ""
echo "Access Keycloak admin:"
echo "  URL:      ${KC_BASE_URL}/auth/admin"
echo "  Username: admin"
echo "  Password: (from Secrets Manager: ${PROJECT_NAME}/keycloak/admin)"
echo ""
echo "Test users (login on Provider realm):"
echo "  • analyst@denodo.com   / Analyst@2026!"
echo "  • scientist@denodo.com / Scientist@2026!"
echo "  • admin@denodo.com     / Admin@2026!"
echo ""
echo -e "${YELLOW}Next step:${NC}"
echo "  Run ./tests/test-all.sh to validate the complete setup"
echo ""
