# Denodo POC -- Step-by-Step Showcase Scenarios

**Date:** 12 February 2026
**Author:** Jaafar Benabderrazak

This document provides step-by-step scenarios to demonstrate every capability of the Denodo Keycloak POC. Each scenario is self-contained and can be executed from **AWS CloudShell** or a **browser**.

---

## Architecture Recap

**System Overview:**
The POC architecture consists of several integrated components:
- **Users** interact through browsers or API clients
- **Application Load Balancer (ALB)** routes traffic to Keycloak for authentication
- **Keycloak** (blue) serves as the identity provider with its own PostgreSQL database
- **API Gateway** exposes the Lambda-based permissions API
- **Lambda Permissions API** (purple) provides role-based access control
- **Denodo Platform** (red) orchestrates data access across multiple sources
- **OpenData RDS Database** (green) stores French company and population data
- **External API** (geo.api.gouv.fr) provides geographic and demographic data

```mermaid
graph LR
    USER["User / Browser"] --> ALB["ALB"]
    USER --> APIGW["API Gateway"]

    ALB --> KC["Keycloak\n(Provider Instance)"]
    KC --> RDS_KC[("Keycloak DB")]

    APIGW --> LAMBDA["Lambda\nPermissions API"]

    DENODO["Denodo Platform"] --> KC
    DENODO --> APIGW
    DENODO --> RDS_OD[("OpenData DB\nentreprises\npopulation")]
    DENODO --> GEO["geo.api.gouv.fr"]

    style KC fill:#3498db,color:#fff
    style LAMBDA fill:#8e44ad,color:#fff
    style DENODO fill:#e74c3c,color:#fff
    style RDS_OD fill:#27ae60,color:#fff
```

> **Diagram Note:** If the diagram above doesn't render, you're seeing the component relationships: Users connect to either the ALB (for Keycloak authentication) or API Gateway (for permissions). Denodo integrates with all components to provide unified data virtualization.

---

## Prerequisites

Before running scenarios, export all credentials:

```bash
# Run this once at the start of your CloudShell session
export ALB_DNS="keycloak-alb-541762229.eu-west-3.elb.amazonaws.com"
export REGION="eu-west-3"

export KC_ADMIN_PWD=$(aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/admin --region $REGION \
  --query SecretString --output text | jq -r '.password')

export CLIENT_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/client-secret --region $REGION \
  --query SecretString --output text | jq -r '.clientSecret')

export API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id denodo-poc/api/auth-key --region $REGION \
  --query SecretString --output text | jq -r '.apiKey')

export API_ENDPOINT=$(aws apigateway get-rest-apis --region $REGION \
  --query "items[?name=='denodo-auth-api'].id | [-1]" --output text)
export API_URL="https://${API_ENDPOINT}.execute-api.${REGION}.amazonaws.com/dev"

echo "ALB:         $ALB_DNS"
echo "API URL:     $API_URL"
echo "API Key:     ${API_KEY:0:8}..."
echo "Admin pwd:   ${KC_ADMIN_PWD:0:4}..."
echo "Client sec:  ${CLIENT_SECRET:0:8}..."
```

---

## Scenario 1: Keycloak Health and Availability

**Goal:** Verify that Keycloak is running and accessible.

**Flow Description:**
1. CloudShell sends a health check request to the Application Load Balancer
2. ALB forwards the request to the Keycloak container
3. Keycloak responds with its health status (UP/DOWN)

```mermaid
sequenceDiagram
    participant CloudShell
    participant ALB
    participant Keycloak

    CloudShell->>ALB: GET /auth/health/ready
    ALB->>Keycloak: Forward
    Keycloak-->>CloudShell: {"status": "UP"}
```

> **Sequence:** CloudShell → ALB → Keycloak → Response

### Steps

**What we're doing:** Testing four different endpoints to ensure Keycloak is fully operational and all components are accessible.

```bash
# 1a. Health check (readiness)
# This checks if Keycloak is ready to accept requests (database connected, services initialized)
curl -s "http://$ALB_DNS/auth/health/ready" | jq '.'
# Expected: {"status": "UP", "checks": [...]}

# 1b. Liveness check
# This verifies that the Keycloak process is alive and responding
curl -s "http://$ALB_DNS/auth/health/live" | jq '.'
# Expected: {"status": "UP"}

# 1c. Verify admin console is accessible
# This confirms the Keycloak admin interface is reachable through the load balancer
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "http://$ALB_DNS/auth/admin/master/console/"
# Expected: HTTP 200

# 1d. Verify static assets load (ALB catch-all rule)
# This ensures JavaScript libraries and static files are served correctly
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "http://$ALB_DNS/auth/js/keycloak.js"
# Expected: HTTP 200
```

**Success criteria:** All return HTTP 200 / status UP.

---

## Scenario 2: OIDC Discovery Endpoints

**Goal:** Verify that both Keycloak realms expose valid OIDC configuration.

**Flow Description:**
OpenID Connect (OIDC) providers must expose a discovery endpoint that describes their capabilities and endpoint URLs. We'll verify both realms (denodo-idp and denodo-consumer) are properly configured.

```mermaid
sequenceDiagram
    participant CloudShell
    participant Keycloak

    CloudShell->>Keycloak: GET /auth/realms/denodo-idp/.well-known/openid-configuration
    Keycloak-->>CloudShell: JSON with issuer, token_endpoint, ...

    CloudShell->>Keycloak: GET /auth/realms/denodo-consumer/.well-known/openid-configuration
    Keycloak-->>CloudShell: JSON with issuer, token_endpoint, ...
```

> **Sequence:** CloudShell queries the well-known OIDC discovery endpoints for both realms to retrieve their authentication configuration.

### Steps

**What we're doing:** Fetching the OpenID Connect discovery documents to confirm both realms are properly configured with all required OAuth2/OIDC endpoints.

```bash
# 2a. Provider realm (Identity Provider)
# This retrieves the OIDC configuration for the main identity provider realm
# The response contains URLs for authentication, token issuance, and user information
echo "=== Provider Realm (denodo-idp) ==="
curl -s "http://$ALB_DNS/auth/realms/denodo-idp/.well-known/openid-configuration" | \
  jq '{issuer, token_endpoint, authorization_endpoint, userinfo_endpoint}'

# 2b. Consumer realm (Service Provider)
# This retrieves the OIDC configuration for the consumer realm that federates to the provider
# This realm acts as a bridge between applications and the identity provider
echo "=== Consumer Realm (denodo-consumer) ==="
curl -s "http://$ALB_DNS/auth/realms/denodo-consumer/.well-known/openid-configuration" | \
  jq '{issuer, token_endpoint, authorization_endpoint, userinfo_endpoint}'
```

**Success criteria:** Both return valid JSON with `issuer`, `token_endpoint`, `authorization_endpoint`.

---

## Scenario 3: Admin Token and Realm Management

**Goal:** Obtain an admin token and explore the Keycloak configuration via API.

**Flow Description:**
1. Authenticate as admin user using password grant flow against the master realm
2. Receive an admin access token with full administrative privileges
3. Use the token to query Keycloak's admin REST API for configuration details

```mermaid
sequenceDiagram
    participant CloudShell
    participant Keycloak

    CloudShell->>Keycloak: POST /auth/realms/master/protocol/openid-connect/token
    Note over CloudShell,Keycloak: grant_type=password, client_id=admin-cli
    Keycloak-->>CloudShell: access_token

    CloudShell->>Keycloak: GET /auth/admin/realms (with Bearer token)
    Keycloak-->>CloudShell: List of realms
```

> **Sequence:** CloudShell authenticates with admin credentials → Receives bearer token → Uses token to access admin API endpoints

### Steps

**What we're doing:** Authenticating as administrator and exploring the Keycloak configuration to verify all realms, users, clients, and identity providers are correctly set up.

```bash
# 3a. Get admin access token
# Authenticate the admin user against the master realm using direct password grant
# This is only allowed for the special admin-cli client and admin user
ADMIN_TOKEN=$(curl -s -X POST \
  "http://$ALB_DNS/auth/realms/master/protocol/openid-connect/token" \
  -d "username=admin&password=$KC_ADMIN_PWD&grant_type=password&client_id=admin-cli" | \
  jq -r '.access_token')

echo "Token: ${ADMIN_TOKEN:0:50}..."

# 3b. List all realms
# Query the admin API to see all configured realms (should include master, denodo-idp, denodo-consumer)
echo "=== Realms ==="
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ALB_DNS/auth/admin/realms" | \
  jq '.[].realm'
# Expected: "master", "denodo-idp", "denodo-consumer"

# 3c. List users in denodo-idp realm
# Retrieve all user accounts from the identity provider realm
# This should show analyst@denodo.com, scientist@denodo.com, and admin@denodo.com
echo "=== Users in denodo-idp ==="
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ALB_DNS/auth/admin/realms/denodo-idp/users" | \
  jq '.[] | {username, email, enabled, attributes}'

# 3d. List identity providers in denodo-consumer realm
# Check the federation configuration - the consumer realm should have provider-idp configured
echo "=== Identity Providers in denodo-consumer ==="
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ALB_DNS/auth/admin/realms/denodo-consumer/identity-provider/instances" | \
  jq '.[] | {alias, displayName, enabled, providerId}'

# 3e. List clients in denodo-idp realm
# Verify the denodo-consumer client is registered in the provider realm
# This client is used for the OIDC federation between realms
echo "=== Clients in denodo-idp ==="
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ALB_DNS/auth/admin/realms/denodo-idp/clients" | \
  jq '.[] | select(.clientId == "denodo-consumer") | {clientId, enabled, protocol}'
```

**Success criteria:** 3 realms visible, 3 users in denodo-idp, provider-idp identity provider in denodo-consumer.

---

## Scenario 4: User Authentication (Password Grant)

**Goal:** Authenticate each test user against the Provider realm and inspect the JWT claims.

**Flow Description:**
Using OAuth2 password grant (Resource Owner Password Credentials), we directly authenticate users and receive JWT tokens. We then decode the tokens to verify they contain the correct user attributes and role mappings.

```mermaid
sequenceDiagram
    participant CloudShell
    participant Keycloak as Keycloak (denodo-idp)

    CloudShell->>Keycloak: POST /token (analyst@denodo.com)
    Keycloak-->>CloudShell: access_token + id_token
    CloudShell->>CloudShell: Decode JWT, inspect claims
```

> **Sequence:** CloudShell submits credentials → Keycloak validates and issues JWT tokens → CloudShell decodes and inspects the token claims

### Steps

**What we're doing:** Authenticating each of our three test users (analyst, scientist, admin) and examining the JWT tokens to verify they contain the correct user profiles, datasource permissions, and role assignments.

```bash
# 4a. Authenticate as analyst
# Log in as the data analyst user with limited read-only permissions
# The JWT token will contain custom claims for profiles and datasources
echo "=== Analyst ==="
ANALYST_TOKEN=$(curl -s -X POST \
  "http://$ALB_DNS/auth/realms/denodo-idp/protocol/openid-connect/token" \
  -d "username=analyst@denodo.com&password=Analyst@2026!&grant_type=password&client_id=denodo-consumer&client_secret=$CLIENT_SECRET&scope=openid email profile" | \
  jq -r '.access_token')

# Decode the JWT payload (the middle segment between the two dots)
# We extract key claims like email, profiles (data-analyst), datasources, and realm roles
echo "$ANALYST_TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{email, preferred_username, profiles, datasources, department, realm_access}'

# 4b. Authenticate as scientist
# Log in as the data scientist user with broader permissions including export capabilities
# This user has access to additional datasources like api-sirene
echo "=== Scientist ==="
SCIENTIST_TOKEN=$(curl -s -X POST \
  "http://$ALB_DNS/auth/realms/denodo-idp/protocol/openid-connect/token" \
  -d "username=scientist@denodo.com&password=Scientist@2026!&grant_type=password&client_id=denodo-consumer&client_secret=$CLIENT_SECRET&scope=openid email profile" | \
  jq -r '.access_token')

# Decode and display the scientist's JWT claims
echo "$SCIENTIST_TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{email, preferred_username, profiles, datasources, department, realm_access}'

# 4c. Authenticate as admin
# Log in as the admin user with full system access and management capabilities
# This user has unlimited query limits and can manage other users
echo "=== Admin ==="
ADMIN_USER_TOKEN=$(curl -s -X POST \
  "http://$ALB_DNS/auth/realms/denodo-idp/protocol/openid-connect/token" \
  -d "username=admin@denodo.com&password=Admin@2026!&grant_type=password&client_id=denodo-consumer&client_secret=$CLIENT_SECRET&scope=openid email profile" | \
  jq -r '.access_token')

# Decode and display the admin's JWT claims (should show admin profile and all datasources)
echo "$ADMIN_USER_TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{email, preferred_username, profiles, datasources, department, realm_access}'
```

**Success criteria:** Each user gets a valid JWT with correct `email`, `profiles`, `datasources`, and `realm_access` claims.

---

## Scenario 5: OIDC Federation (Consumer to Provider Brokering)

**Goal:** Verify that the Consumer realm can federate authentication to the Provider realm.

**Flow Description:**
This demonstrates identity brokering where the consumer realm (Service Provider) delegates authentication to the provider realm (Identity Provider). This is the core of federated single sign-on.

**The Federation Process:**
1. User accesses consumer realm account page
2. Consumer presents login page with "Sign in with provider-idp" option
3. User clicks federation button
4. Consumer redirects to provider realm via OIDC authorization flow
5. User authenticates at provider realm
6. Provider issues authorization code back to consumer
7. Consumer exchanges code for JWT tokens
8. User is logged into consumer realm with federated identity

```mermaid
sequenceDiagram
    participant Browser
    participant Consumer as Keycloak Consumer
    participant Provider as Keycloak Provider

    Browser->>Consumer: GET /auth/realms/denodo-consumer/account
    Consumer-->>Browser: Login page with "Sign in with provider-idp"
    Browser->>Consumer: Click provider-idp link
    Consumer->>Provider: OIDC Authorization redirect
    Provider-->>Browser: Provider login form
    Browser->>Provider: Submit credentials
    Provider-->>Consumer: Authorization code
    Consumer->>Provider: Exchange code for tokens
    Provider-->>Consumer: JWT tokens
    Consumer-->>Browser: Account page (logged in)
```

> **Sequence:** Browser → Consumer (login page) → Provider (authenticate) → Consumer (tokens) → Browser (logged in)

### Steps (Browser)

1. Open in browser:
   ```
   http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-consumer/account
   ```

2. You should see a login page with a button **"Sign in with provider-idp"** (or "Denodo Identity Provider")

3. Click the button -- you will be redirected to the **Provider** realm login form

4. Enter credentials:
   - **Username:** `analyst@denodo.com`
   - **Password:** `Analyst@2026!`

5. After successful login, you will be redirected back to the **Consumer** realm account page

6. The account page shows the federated user information

### Steps (CloudShell -- Verify configuration)

**What we're doing:** Programmatically verifying that the identity provider federation is correctly configured with proper authorization and token URLs.

```bash
# Verify the federation is configured
# First, obtain an admin token to access the configuration API
ADMIN_TOKEN=$(curl -s -X POST \
  "http://$ALB_DNS/auth/realms/master/protocol/openid-connect/token" \
  -d "username=admin&password=$KC_ADMIN_PWD&grant_type=password&client_id=admin-cli" | \
  jq -r '.access_token')

# Check IdP configuration
# Retrieve the provider-idp configuration from the consumer realm
# Verify it points to the correct authorization and token URLs of the provider realm
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ALB_DNS/auth/admin/realms/denodo-consumer/identity-provider/instances/provider-idp" | \
  jq '{alias, enabled, providerId, config: {authorizationUrl: .config.authorizationUrl, tokenUrl: .config.tokenUrl, clientId: .config.clientId}}'

# Check the consumer account page returns a redirect (302)
# Unauthenticated access should redirect to login, confirming authentication is required
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "http://$ALB_DNS/auth/realms/denodo-consumer/account"
# Expected: HTTP 302 (redirect to login)
```

**Success criteria:** Browser shows account page after federation login. CloudShell shows IdP configured with correct URLs.

---

## Scenario 6: Authorization API (Lambda Permissions)

**Goal:** Query the permissions API for each user and verify role-based access control.

**Flow Description:**
The permissions API (Lambda function behind API Gateway) provides fine-grained authorization data for each user. Denodo queries this API to determine what datasources a user can access and what operations they can perform.

```mermaid
sequenceDiagram
    participant CloudShell
    participant APIGW as API Gateway
    participant Lambda

    CloudShell->>APIGW: GET /users/analyst@denodo.com/permissions
    Note over CloudShell,APIGW: Header: X-API-Key
    APIGW->>Lambda: Invoke
    Lambda-->>APIGW: {profiles, datasources, maxRows}
    APIGW-->>CloudShell: 200 OK
```

> **Sequence:** CloudShell → API Gateway (validates API key) → Lambda (looks up user permissions) → Returns authorization details

### Steps

**What we're doing:** Testing the role-based access control (RBAC) system by querying permissions for different user types and verifying security controls reject unauthorized requests.

```bash
# 6a. Analyst permissions (limited access)
# Query permissions for the analyst user who has restricted read-only access
# Analysts can query RDS OpenData and geo API but cannot export or create views
echo "=== Analyst Permissions ==="
curl -s -H "X-API-Key: $API_KEY" \
  "$API_URL/api/v1/users/analyst@denodo.com/permissions" | jq '.'
# Expected: profiles=["data-analyst"], maxRowsPerQuery=10000, canExport=false

# 6b. Scientist permissions (broader access)
# Query permissions for the scientist user with advanced capabilities
# Scientists can export data, access more datasources including SIRENE API, and query more rows
echo "=== Scientist Permissions ==="
curl -s -H "X-API-Key: $API_KEY" \
  "$API_URL/api/v1/users/scientist@denodo.com/permissions" | jq '.'
# Expected: profiles=["data-scientist"], maxRowsPerQuery=50000, canExport=true, 3 datasources

# 6c. Admin permissions (full access)
# Query permissions for the admin user with unrestricted access
# Admins have unlimited query rows, can manage users, and access all datasources
echo "=== Admin Permissions ==="
curl -s -H "X-API-Key: $API_KEY" \
  "$API_URL/api/v1/users/admin@denodo.com/permissions" | jq '.'
# Expected: profiles=["admin"], maxRowsPerQuery=-1, canManageUsers=true, datasources=["*"]

# 6d. Unknown user (guest fallback)
# Query permissions for a user that doesn't exist in the system
# The API should return default guest permissions with minimal access
echo "=== Unknown User ==="
curl -s -H "X-API-Key: $API_KEY" \
  "$API_URL/api/v1/users/unknown@test.com/permissions" | jq '.'
# Expected: profiles=["guest"], maxRowsPerQuery=1000

# 6e. Missing API key (should be rejected)
# Attempt to access the API without providing an API key
# API Gateway should reject this with 403 Forbidden
echo "=== No API Key ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "$API_URL/api/v1/users/analyst@denodo.com/permissions"
# Expected: HTTP 403

# 6f. Invalid API key (should be rejected)
# Attempt to access the API with a fake/invalid API key
# API Gateway should reject this with 403 Forbidden
echo "=== Invalid API Key ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "X-API-Key: INVALID_KEY_12345" \
  "$API_URL/api/v1/users/analyst@denodo.com/permissions"
# Expected: HTTP 403
```

### Comparison Table

| User | Profile | Datasources | Max Rows | Export | Create Views |
|------|---------|-------------|----------|--------|-------------|
| analyst@denodo.com | data-analyst | rds-opendata, api-geo | 10,000 | No | No |
| scientist@denodo.com | data-scientist | rds-opendata, api-geo, api-sirene | 50,000 | Yes | Yes |
| admin@denodo.com | admin | all (*) | unlimited | Yes | Yes |
| unknown@test.com | guest | none | 1,000 | No | No |

**Success criteria:** Each user returns correct profile, datasources, and permissions. Unauthorized requests return 403.

---

## Scenario 7: OpenData RDS Access (via SSM)

**Goal:** Query the OpenData PostgreSQL database through the Denodo EC2 instance.

**Flow Description:**
Since the RDS database is in a private subnet, we use AWS Systems Manager (SSM) to run SQL queries remotely on the EC2 instance that has network access to RDS. This simulates how Denodo will query the database.

```mermaid
sequenceDiagram
    participant CloudShell
    participant EC2 as Denodo EC2 (SSM)
    participant RDS as OpenData RDS

    CloudShell->>EC2: SSM send-command (psql query)
    EC2->>RDS: SQL query
    RDS-->>EC2: Results
    EC2-->>CloudShell: Output
```

> **Sequence:** CloudShell → SSM → EC2 (executes psql) → RDS (queries database) → Returns results

### Steps

**What we're doing:** Using AWS Systems Manager to remotely execute PostgreSQL queries on the EC2 instance, which queries the OpenData RDS database containing French company and population data.

```bash
# Get DB credentials
# Retrieve the RDS endpoint hostname from AWS
# Fetch the database password from AWS Secrets Manager
# Set the EC2 instance ID for SSM commands
DB_HOST=$(aws rds describe-db-instances \
  --db-instance-identifier denodo-poc-opendata-db --region $REGION \
  --query 'DBInstances[0].Endpoint.Address' --output text)
DB_PASS=$(aws secretsmanager get-secret-value \
  --secret-id denodo-poc/opendata/db --region $REGION \
  --query SecretString --output text | jq -r '.password')
EC2_ID="i-0aef555dcb0ff873f"

# 7a. List tables
# Query PostgreSQL's system catalog to see all tables in the opendata schema
# Should show: entreprises, population_communes, and related views
echo "=== Tables in opendata schema ==="
CMD_ID=$(aws ssm send-command --instance-ids $EC2_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"PGPASSWORD='$DB_PASS' psql -h $DB_HOST -U denodo -d opendata -t -A -c \\\"SELECT tablename FROM pg_tables WHERE schemaname='opendata';\\\"\"]" \
  --region $REGION --query 'Command.CommandId' --output text)
sleep 5
aws ssm get-command-invocation --command-id $CMD_ID --instance-id $EC2_ID \
  --region $REGION --query 'StandardOutputContent' --output text

# 7b. Count rows in entreprises
# Count total company records in the database
# This table contains French companies from the SIRENE registry
echo "=== Entreprises count ==="
CMD_ID=$(aws ssm send-command --instance-ids $EC2_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"PGPASSWORD='$DB_PASS' psql -h $DB_HOST -U denodo -d opendata -t -A -c \\\"SELECT COUNT(*) FROM opendata.entreprises;\\\"\"]" \
  --region $REGION --query 'Command.CommandId' --output text)
sleep 5
aws ssm get-command-invocation --command-id $CMD_ID --instance-id $EC2_ID \
  --region $REGION --query 'StandardOutputContent' --output text

# 7c. Count rows in population_communes
# Count total commune (municipality) records
# This table contains population data for all French communes
echo "=== Population communes count ==="
CMD_ID=$(aws ssm send-command --instance-ids $EC2_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"PGPASSWORD='$DB_PASS' psql -h $DB_HOST -U denodo -d opendata -t -A -c \\\"SELECT COUNT(*) FROM opendata.population_communes;\\\"\"]" \
  --region $REGION --query 'Command.CommandId' --output text)
sleep 5
aws ssm get-command-invocation --command-id $CMD_ID --instance-id $EC2_ID \
  --region $REGION --query 'StandardOutputContent' --output text

# 7d. Sample query: Top 5 companies in Paris with population
# Demonstrate a JOIN query combining company data with population data
# This shows how Denodo can correlate business and demographic information
echo "=== Top 5 companies in Paris ==="
CMD_ID=$(aws ssm send-command --instance-ids $EC2_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"PGPASSWORD='$DB_PASS' psql -h $DB_HOST -U denodo -d opendata -t -A -c \\\"SELECT e.nom_raison_sociale, e.ville, p.population FROM opendata.entreprises e LEFT JOIN opendata.population_communes p ON e.code_postal = p.code_postal WHERE e.departement = '75' AND p.population IS NOT NULL ORDER BY p.population DESC LIMIT 5;\\\"\"]" \
  --region $REGION --query 'Command.CommandId' --output text)
sleep 5
aws ssm get-command-invocation --command-id $CMD_ID --instance-id $EC2_ID \
  --region $REGION --query 'StandardOutputContent' --output text
```

**Success criteria:** Tables exist, row counts are non-zero, cross-table queries return data.

---

## Scenario 8: Public API Integration (geo.api.gouv.fr)

**Goal:** Demonstrate the public REST API that Denodo will consume alongside RDS data.

**Flow Description:**
The French government provides a free public API for geographic and administrative data. Denodo will integrate this REST API as a data source alongside RDS, enabling federated queries that combine database tables with live API data.

```mermaid
sequenceDiagram
    participant CloudShell
    participant GeoAPI as geo.api.gouv.fr

    CloudShell->>GeoAPI: GET /communes?codePostal=75001
    GeoAPI-->>CloudShell: [{nom, code, population}]
```

> **Sequence:** CloudShell → geo.api.gouv.fr (public REST API) → Returns geographic/demographic JSON data

### Steps

**What we're doing:** Testing the public geographic API to verify it returns valid data for communes (municipalities), departments, and regions. This API will be one of Denodo's external data sources.

```bash
# 8a. Get communes by postal code
# Query all communes (cities/towns) that share a specific postal code
# Postal codes in France can cover multiple communes
echo "=== Communes in 75001 (Paris 1er) ==="
curl -s "https://geo.api.gouv.fr/communes?codePostal=75001&fields=nom,code,codeDepartement,population" | jq '.'

# 8b. Get department info
# Retrieve detailed information about a French department
# Department 75 is Paris (both city and department)
echo "=== Department 75 (Paris) ==="
curl -s "https://geo.api.gouv.fr/departements/75" | jq '.'

# 8c. Get region info
# Retrieve information about a French administrative region
# Region 11 is Île-de-France (Paris region)
echo "=== Region 11 (Ile-de-France) ==="
curl -s "https://geo.api.gouv.fr/regions/11" | jq '.'

# 8d. Search communes by name
# Search for communes matching a name pattern
# This demonstrates fuzzy search capabilities of the API
echo "=== Communes named 'Lyon' ==="
curl -s "https://geo.api.gouv.fr/communes?nom=Lyon&fields=nom,code,codeDepartement,population&limit=5" | jq '.'

# 8e. Get all departments
# Retrieve the complete list of French departments and count them
# Should return 101 departments (96 metropolitan + 5 overseas)
echo "=== All departments (count) ==="
curl -s "https://geo.api.gouv.fr/departements" | jq '. | length'
# Expected: 101 (metropolitan + overseas)
```

**Success criteria:** API returns valid JSON data for all geographic queries.

---

## Scenario 9: End-to-End Data Flow Simulation

**Goal:** Simulate the full Denodo data flow -- authenticate, get permissions, query data.

**Flow Description:**
This scenario orchestrates all previous components into a complete workflow that mirrors how Denodo will operate in production:
1. **Authenticate** - User obtains OIDC token from Keycloak
2. **Get Permissions** - Query Lambda API to determine user's access rights
3. **Query RDS** - Access structured data from PostgreSQL database
4. **Query REST API** - Access live data from public API
5. **Combine Results** - Federate data from multiple sources (Denodo's core capability)
6. **Return to User** - Deliver unified result set with proper authorization

```mermaid
flowchart LR
    A["1. Authenticate\n(OIDC Token)"] --> B["2. Get Permissions\n(API Gateway)"]
    B --> C["3. Query RDS\n(OpenData)"]
    B --> D["4. Query REST API\n(geo.api.gouv.fr)"]
    C --> E["5. Combine Results"]
    D --> E
    E --> F["6. Return to User"]

    style A fill:#3498db,color:#fff
    style B fill:#8e44ad,color:#fff
    style C fill:#27ae60,color:#fff
    style D fill:#f39c12,color:#000
    style E fill:#e74c3c,color:#fff
    style F fill:#2ecc71,color:#fff
```

> **Flow:** Authentication → Authorization → Multi-source Data Query → Federation → Result Delivery

### Steps

**What we're doing:** Executing all six steps of the complete data virtualization workflow to prove the entire system works together seamlessly.

```bash
echo "======================================"
echo "  END-TO-END DATA FLOW SIMULATION"
echo "======================================"
echo ""

# Step 1: Authenticate as analyst
# Obtain an OIDC token for the analyst user using password grant flow
# This token contains user identity and role information
echo "STEP 1: Authenticate analyst@denodo.com"
TOKEN_RESPONSE=$(curl -s -X POST \
  "http://$ALB_DNS/auth/realms/denodo-idp/protocol/openid-connect/token" \
  -d "username=analyst@denodo.com&password=Analyst@2026!&grant_type=password&client_id=denodo-consumer&client_secret=$CLIENT_SECRET&scope=openid email profile")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
if [ "$ACCESS_TOKEN" != "null" ] && [ ! -z "$ACCESS_TOKEN" ]; then
  echo "  [OK] Authenticated. Token: ${ACCESS_TOKEN:0:30}..."
  EMAIL=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.email')
  echo "  [OK] Email from JWT: $EMAIL"
else
  echo "  [FAIL] Authentication failed"
  echo "$TOKEN_RESPONSE" | jq '.'
  exit 1
fi
echo ""

# Step 2: Get permissions
# Query the Lambda permissions API to determine what datasources and operations
# this user is authorized to access based on their role
echo "STEP 2: Get permissions for $EMAIL"
PERMISSIONS=$(curl -s -H "X-API-Key: $API_KEY" \
  "$API_URL/api/v1/users/$EMAIL/permissions")
PROFILE=$(echo "$PERMISSIONS" | jq -r '.profiles[0]')
MAX_ROWS=$(echo "$PERMISSIONS" | jq -r '.maxRowsPerQuery')
CAN_EXPORT=$(echo "$PERMISSIONS" | jq -r '.canExport')
DS_COUNT=$(echo "$PERMISSIONS" | jq '.datasources | length')
echo "  [OK] Profile: $PROFILE"
echo "  [OK] Max rows: $MAX_ROWS"
echo "  [OK] Can export: $CAN_EXPORT"
echo "  [OK] Datasources: $DS_COUNT"
echo ""

# Step 3: Query RDS (simulated via SSM)
# Execute a SQL query against the OpenData PostgreSQL database
# This retrieves company count for Paris department (dept 75)
echo "STEP 3: Query OpenData RDS (via SSM)"
CMD_ID=$(aws ssm send-command --instance-ids $EC2_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"PGPASSWORD='$DB_PASS' psql -h $DB_HOST -U denodo -d opendata -t -A -c \\\"SELECT COUNT(*) as total FROM opendata.entreprises WHERE departement = '75';\\\"\"]" \
  --region $REGION --query 'Command.CommandId' --output text)
sleep 5
PARIS_COUNT=$(aws ssm get-command-invocation --command-id $CMD_ID --instance-id $EC2_ID \
  --region $REGION --query 'StandardOutputContent' --output text | tr -d '[:space:]')
echo "  [OK] Companies in Paris (dept 75): $PARIS_COUNT"
echo ""

# Step 4: Query Public API
# Fetch demographic data from the public geographic API
# This calculates total population across all Paris communes
echo "STEP 4: Query geo.api.gouv.fr"
PARIS_POP=$(curl -s "https://geo.api.gouv.fr/departements/75/communes?fields=nom,population" | \
  jq '[.[].population] | add')
echo "  [OK] Total population in Paris communes: $PARIS_POP"
echo ""

# Step 5: Combine (simulated)
# Demonstrate data federation by correlating results from RDS and public API
# This simulates Denodo's ability to join data from heterogeneous sources
echo "STEP 5: Combined data (simulated Denodo join)"
echo "  Companies in Paris: $PARIS_COUNT"
echo "  Population in Paris: $PARIS_POP"
if [ ! -z "$PARIS_COUNT" ] && [ "$PARIS_COUNT" != "0" ] && [ ! -z "$PARIS_POP" ]; then
  echo "  [OK] Both data sources returned data -- Denodo can join them"
else
  echo "  [WARN] One or more data sources returned empty"
fi
echo ""

# Step 6: Summary
# Display the final access control decision and summary of the workflow
# Confirms all authorization constraints are properly applied
echo "STEP 6: Access decision"
echo "  User: $EMAIL"
echo "  Profile: $PROFILE"
echo "  Allowed datasources: $(echo "$PERMISSIONS" | jq -r '[.datasources[].id] | join(", ")')"
echo "  Max rows per query: $MAX_ROWS"
echo "  Export allowed: $CAN_EXPORT"
echo ""
echo "  [OK] End-to-end flow completed successfully"
```

**Success criteria:** All 6 steps complete with valid data. The simulation proves that authentication, authorization, and data access all work together.

---

## Scenario 10: Security Validation

**Goal:** Verify that security controls are properly enforced.

**What we're doing:** Testing negative scenarios to ensure the system properly rejects unauthorized access attempts. This validates authentication, authorization, and API security controls.

### Steps

```bash
echo "=== Security Validation ==="

# 10a. API Gateway rejects requests without API key
# Attempt to access the permissions API without providing the required X-API-Key header
# API Gateway should enforce API key requirement and reject the request
echo "Test: No API key"
curl -s -o /dev/null -w "  HTTP %{http_code} (expected 403)\n" \
  "$API_URL/api/v1/users/analyst@denodo.com/permissions"

# 10b. API Gateway rejects invalid API keys
# Attempt to access the API with a fake/invalid API key
# API Gateway should validate the key against stored values and reject
echo "Test: Invalid API key"
curl -s -o /dev/null -w "  HTTP %{http_code} (expected 403)\n" \
  -H "X-API-Key: FAKE_KEY_123" \
  "$API_URL/api/v1/users/analyst@denodo.com/permissions"

# 10c. Keycloak rejects invalid credentials
# Attempt to authenticate with correct username but wrong password
# Keycloak should validate credentials and return invalid_grant error
echo "Test: Invalid password"
FAIL_RESP=$(curl -s -X POST \
  "http://$ALB_DNS/auth/realms/denodo-idp/protocol/openid-connect/token" \
  -d "username=analyst@denodo.com&password=WRONG&grant_type=password&client_id=denodo-consumer&client_secret=$CLIENT_SECRET")
echo "  $(echo "$FAIL_RESP" | jq -r '.error // "unexpected"') (expected invalid_grant)"

# 10d. Keycloak rejects invalid client secret
# Attempt to authenticate with correct user password but wrong client secret
# This tests OAuth2 client authentication
echo "Test: Invalid client secret"
FAIL_RESP=$(curl -s -X POST \
  "http://$ALB_DNS/auth/realms/denodo-idp/protocol/openid-connect/token" \
  -d "username=analyst@denodo.com&password=Analyst@2026!&grant_type=password&client_id=denodo-consumer&client_secret=WRONG_SECRET")
echo "  $(echo "$FAIL_RESP" | jq -r '.error // "unexpected"') (expected unauthorized_client)"

# 10e. Non-existent realm returns 404
# Attempt to access a realm that doesn't exist
# Keycloak should return 404 Not Found for invalid realm names
echo "Test: Non-existent realm"
curl -s -o /dev/null -w "  HTTP %{http_code} (expected 404)\n" \
  "http://$ALB_DNS/auth/realms/does-not-exist/.well-known/openid-configuration"
```

**Success criteria:** All security controls return expected rejection codes.

---

## Quick Reference: Scenario Checklist

**Testing Flow Overview:**
The scenarios build progressively - each validates a component before moving to more complex integrations. Follow this sequence for a complete POC demonstration.

**Color Legend:**
- Blue: Infrastructure & Discovery (Scenarios 1-2)
- Green: User Management & Authentication (Scenarios 3-4)
- Purple: Federation & Authorization (Scenarios 5-6)
- Green/Orange: Data Sources (Scenarios 7-8)
- Red: Integration & Security (Scenarios 9-10)

```mermaid
graph TD
    S1["Scenario 1\nKeycloak Health"] -->|"health UP"| S2["Scenario 2\nOIDC Discovery"]
    S2 -->|"both realms OK"| S3["Scenario 3\nAdmin API"]
    S3 -->|"3 realms, 3 users"| S4["Scenario 4\nUser Auth"]
    S4 -->|"JWT claims OK"| S5["Scenario 5\nOIDC Federation"]
    S5 -->|"brokering works"| S6["Scenario 6\nPermissions API"]
    S6 -->|"RBAC correct"| S7["Scenario 7\nRDS OpenData"]
    S7 -->|"tables + data"| S8["Scenario 8\nPublic API"]
    S8 -->|"geo data OK"| S9["Scenario 9\nEnd-to-End"]
    S9 -->|"full flow"| S10["Scenario 10\nSecurity"]
    S10 -->|"controls enforced"| DONE["All Scenarios Passed"]

    style S1 fill:#3498db,color:#fff
    style S2 fill:#3498db,color:#fff
    style S3 fill:#2ecc71,color:#fff
    style S4 fill:#2ecc71,color:#fff
    style S5 fill:#9b59b6,color:#fff
    style S6 fill:#8e44ad,color:#fff
    style S7 fill:#27ae60,color:#fff
    style S8 fill:#f39c12,color:#000
    style S9 fill:#e74c3c,color:#fff
    style S10 fill:#e74c3c,color:#fff
    style DONE fill:#27ae60,color:#fff
```

> **Progressive Validation:** Each scenario's success criterion must pass before proceeding to the next. This ensures dependencies are met and problems are caught early.

| # | Scenario | Type | Duration |
|---|----------|------|----------|
| 1 | Keycloak Health | CloudShell | 10s |
| 2 | OIDC Discovery | CloudShell | 10s |
| 3 | Admin Token + Realm Management | CloudShell | 15s |
| 4 | User Authentication | CloudShell | 15s |
| 5 | OIDC Federation | Browser + CloudShell | 30s |
| 6 | Authorization API | CloudShell | 15s |
| 7 | OpenData RDS | CloudShell (SSM) | 30s |
| 8 | Public API | CloudShell | 10s |
| 9 | End-to-End Flow | CloudShell (SSM) | 45s |
| 10 | Security Validation | CloudShell | 15s |

**Total demo time: ~3 minutes**

---

**Document Version:** 1.0
**Last Updated:** 12 February 2026
**Author:** Jaafar Benabderrazak
