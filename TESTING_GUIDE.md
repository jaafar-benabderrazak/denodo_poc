# Denodo POC - Testing & Access Guide

## Current Deployment Status ✅

Your Denodo POC infrastructure is **95% complete**:

- ✅ **3 RDS Databases**: Provider, Consumer, OpenData (with 34,969 communes + 988 entreprises)
- ✅ **ECS Cluster**: 2 Keycloak instances running
- ✅ **Application Load Balancer**: Active and routing
- ✅ **Lambda Function**: Permissions API deployed
- ✅ **Secrets Manager**: All credentials secured
- ⚠️ **API Gateway**: Needs deployment (optional)

---

## Step 1: Deploy API Gateway (Complete the Setup)

Run in CloudShell:

```bash
./scripts/deploy-lambda-api.sh
```

**What this does:**
- Creates HTTP API Gateway
- Links it to the Lambda permissions function
- Configures API key authentication
- Provides REST endpoint for authorization lookups

**Duration:** ~3-5 minutes

---

## Step 2: Access Keycloak Admin Console

### Get Admin Credentials

```bash
# Get admin password
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/admin \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.password')

echo "Username: admin"
echo "Password: $ADMIN_PASSWORD"
```

### Access URLs

**Keycloak Provider (Identity Provider):**
```
http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/admin/master/console/#/denodo-idp
```

**Keycloak Consumer (Service Provider):**
```
http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/admin/master/console/#/denodo-consumer
```

**Base Keycloak URL:**
```
http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth
```

---

## Step 3: Verify Keycloak Configuration

### Check Realms

1. **Provider Realm**: `denodo-idp`
   - Users: analyst@denodo.com, scientist@denodo.com, admin@denodo.com
   - Roles: data-analyst, data-scientist, admin
   - Attributes: datasources, permissions

2. **Consumer Realm**: `denodo-consumer`
   - OIDC Federation configured to Provider
   - Identity Provider: provider-idp
   - Mappers: email, username, roles

### Test Users

| Username | Password | Profile | Datasources |
|----------|----------|---------|-------------|
| analyst@denodo.com | Analyst@2026! | data-analyst | rds-opendata, api-geo |
| scientist@denodo.com | Scientist@2026! | data-scientist | rds-opendata, api-geo, api-sirene |
| admin@denodo.com | Admin@2026! | admin | all |

---

## Step 4: Test Authentication Flow

### Manual Browser Test (OIDC Flow)

1. Navigate to Consumer realm login:
   ```
   http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-consumer/account
   ```

2. Click **"Sign in with provider-idp"**

3. You'll be redirected to Provider realm login

4. Login with test user (e.g., `analyst@denodo.com` / `Analyst@2026!`)

5. After authentication, you'll be redirected back to Consumer

6. Check user attributes and roles are mapped

### Programmatic Test (Token Exchange)

```bash
# Get Provider token
PROVIDER_TOKEN=$(curl -s -X POST \
  "http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-idp/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=analyst@denodo.com" \
  -d "password=Analyst@2026!" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

echo "Provider Token: ${PROVIDER_TOKEN:0:50}..."

# Decode token to see claims
echo "$PROVIDER_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```

---

## Step 5: Test Authorization API

### Get API Configuration

```bash
# API Gateway endpoint (after deployment)
API_ENDPOINT=$(cat deployment-info.json | jq -r '.apiGatewayEndpoint')

# API Key
API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id denodo-poc/api/auth-key \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.apiKey')

echo "API Endpoint: $API_ENDPOINT"
echo "API Key: ${API_KEY:0:20}..."
```

### Test Permissions Lookup

```bash
# Check analyst permissions
curl -H "X-API-Key: $API_KEY" \
  "$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions" | jq .

# Expected response:
# {
#   "user": "analyst@denodo.com",
#   "profile": "data-analyst",
#   "datasources": ["rds-opendata", "api-geo"],
#   "permissions": {
#     "rds-opendata": ["SELECT"],
#     "api-geo": ["READ"]
#   }
# }
```

```bash
# Check scientist permissions
curl -H "X-API-Key: $API_KEY" \
  "$API_ENDPOINT/api/v1/users/scientist@denodo.com/permissions" | jq .

# Check admin permissions
curl -H "X-API-Key: $API_KEY" \
  "$API_ENDPOINT/api/v1/users/admin@denodo.com/permissions" | jq .
```

---

## Step 6: Test RDS OpenData Access

### From CloudShell (via diagnostic script)

```bash
./scripts/diagnose-rds.sh
```

**Expected output:**
- ✅ Connection successful
- ✅ Database `opendata` exists
- ✅ Schema `opendata` exists
- ✅ Tables: entreprises (988 rows), population_communes (34,969 rows)

### Query Examples

The diagnostic script routes through SSM, so you can't run queries directly from CloudShell. However, from the Denodo EC2 or via SSM:

```sql
-- Top 10 communes by population
SELECT nom_commune, population, code_departement
FROM opendata.population_communes
ORDER BY population DESC
LIMIT 10;

-- Companies by department
SELECT departement, COUNT(*) as company_count
FROM opendata.entreprises
WHERE statut = 'Actif'
GROUP BY departement
ORDER BY company_count DESC;

-- Join companies with population data
SELECT 
    e.nom_raison_sociale,
    e.ville,
    p.nom_commune,
    p.population
FROM opendata.entreprises e
LEFT JOIN opendata.population_communes p 
    ON e.code_postal = p.code_postal
LIMIT 20;
```

---

## Step 7: Connect Denodo Platform

### Configure Denodo Data Sources

#### RDS OpenData Connection

```yaml
Type: PostgreSQL
Connection:
  Host: denodo-poc-opendata-db.cacjdkje8yxa.eu-west-3.rds.amazonaws.com
  Port: 5432
  Database: opendata
  Schema: opendata
  
Credentials:
  Username: denodo
  Password: [from Secrets Manager: denodo-poc/opendata/db]
  
Tables:
  - entreprises (988 rows)
  - population_communes (34,969 rows)
  - entreprises_population (view, 988 rows)
```

**Get Password:**
```bash
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/opendata/db \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.password'
```

#### Keycloak OIDC Authentication

```yaml
Type: OIDC (OpenID Connect)
Provider: Keycloak Consumer
Configuration:
  Issuer URL: http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-consumer
  Client ID: denodo-consumer
  Client Secret: [from Secrets Manager: denodo-poc/keycloak/client-secret]
  Redirect URI: [Your Denodo callback URL]
  Scopes: openid, email, profile
  
User Mapping:
  - Email → email claim
  - Username → preferred_username claim
  - Roles → roles claim
```

**Get Client Secret:**
```bash
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/client-secret \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.clientSecret'
```

#### Authorization API Integration

```yaml
Type: REST API
Base URL: [From deployment-info.json: apiGatewayEndpoint]
Authentication: API Key (X-API-Key header)
API Key: [from Secrets Manager: denodo-poc/api/auth-key]

Endpoints:
  - GET /api/v1/users/{email}/permissions
  - GET /api/v1/users/{email}/datasources
```

---

## Step 8: Run Comprehensive Tests

```bash
# All tests
./tests/test-all.sh

# Individual tests
./tests/test-authentication.sh    # OIDC flow
./tests/test-authorization.sh     # Lambda API
./tests/test-data-sources.sh      # RDS + API connectivity
```

---

## Monitoring & Troubleshooting

### View Logs

```bash
# Keycloak Provider logs
aws logs tail /ecs/keycloak-provider --follow --region eu-west-3

# Keycloak Consumer logs
aws logs tail /ecs/keycloak-consumer --follow --region eu-west-3

# Lambda API logs
aws logs tail /aws/lambda/denodo-permissions-api --follow --region eu-west-3
```

### Check Service Health

```bash
# ECS services
aws ecs describe-services \
  --cluster denodo-keycloak-cluster \
  --services keycloak-provider keycloak-consumer \
  --region eu-west-3 \
  --query 'services[].[serviceName,status,runningCount,desiredCount]' \
  --output table

# ALB health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names keycloak-provider-tg \
    --region eu-west-3 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text) \
  --region eu-west-3
```

### Common Issues

**Issue: Keycloak not accessible**
- Check ECS tasks are running: `aws ecs list-tasks --cluster denodo-keycloak-cluster --region eu-west-3`
- Check ALB health: See command above
- Check security groups allow port 8080

**Issue: OIDC federation failing**
- Verify client secret matches in both realms
- Check Provider realm issuer URL is correct
- Review Provider logs for authentication attempts

**Issue: Cannot connect to RDS from Denodo**
- Ensure Denodo EC2 IP (10.0.75.195) is in OpenData RDS security group
- Test connectivity: `./scripts/diagnose-rds.sh`
- Verify credentials are correct

---

## Quick Reference

| Resource | Value |
|----------|-------|
| **Region** | eu-west-3 |
| **VPC** | vpc-08ffb9d90f07533d0 |
| **ALB DNS** | keycloak-alb-541762229.eu-west-3.elb.amazonaws.com |
| **Keycloak Base** | http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth |
| **Provider Realm** | denodo-idp |
| **Consumer Realm** | denodo-consumer |
| **RDS OpenData** | denodo-poc-opendata-db.cacjdkje8yxa.eu-west-3.rds.amazonaws.com |
| **Database** | opendata |
| **Schema** | opendata |
| **Lambda Function** | denodo-permissions-api |

---

## Next Steps

1. ✅ **Deploy API Gateway** (if not done): `./scripts/deploy-lambda-api.sh`
2. ✅ **Test Keycloak**: Access admin console and verify realms
3. ✅ **Test OIDC Flow**: Login through Consumer → Provider federation
4. ✅ **Test Authorization API**: Query user permissions
5. ✅ **Connect Denodo**: Configure data sources and authentication
6. ✅ **Run Tests**: Verify end-to-end functionality

---

**Version:** 1.0  
**Last Updated:** February 12, 2026  
**Maintainer:** Jaafar Benabderrazak
