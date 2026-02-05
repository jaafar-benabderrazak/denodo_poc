# Denodo Keycloak POC - Deployment Guide

## Quick Start

This project deploys a complete Keycloak federation setup for Denodo data virtualization with OpenData sources.

### Architecture

- **2 Keycloak instances** (Provider + Consumer) on ECS Fargate with OIDC federation
- **3 RDS PostgreSQL databases** (2 for Keycloak, 1 for OpenData)
- **Application Load Balancer** for Keycloak access
- **Lambda Authorization API** for permissions management
- **French OpenData** (SIRENE companies + population data)
- **Public API integration** (geo.api.gouv.fr)

### Prerequisites

```bash
# Required tools
- AWS CLI v2+ configured
- jq (JSON processor)
- curl
- PostgreSQL client (psql) - optional for database access

# AWS Permissions Required
- EC2 (VPC, Security Groups, Subnets)
- ECS (Cluster, Services, Task Definitions)
- RDS (Database instances)
- Secrets Manager
- IAM (Roles, Policies)
- CloudWatch Logs
- Lambda
- API Gateway
- Application Load Balancer
```

### Deployment Steps

#### Option 1: CloudShell One-Command Deployment (Recommended)

```bash
# Upload this folder to CloudShell
cd denodo-keycloak-poc

# Make script executable
chmod +x scripts/*.sh

# Run complete deployment
./scripts/deploy-denodo-keycloak.sh
```

**Time:** ~45 minutes total

####Option 2: Step-by-Step Deployment

```bash
# Step 1: Infrastructure (20 min)
./scripts/deploy-denodo-keycloak.sh

# Step 2: ECS Cluster & Keycloak (15 min)  
./scripts/deploy-ecs-keycloak.sh

# Step 3: Load OpenData (5 min)
./scripts/load-opendata.sh

# Step 4: Configure OIDC Federation (2 min)
./scripts/configure-keycloak.sh

# Step 5: Deploy Lambda API (3 min)
./scripts/deploy-lambda-api.sh
```

### What Gets Created

| Resource | Name | Purpose |
|----------|------|---------|
| ECS Cluster | denodo-keycloak-cluster | Container orchestration |
| ECS Service | keycloak-provider | Identity Provider |
| ECS Service | keycloak-consumer | Service Provider (federated) |
| RDS Instance | denodo-poc-keycloak-provider-db | Keycloak Provider DB |
| RDS Instance | denodo-poc-keycloak-consumer-db | Keycloak Consumer DB |
| RDS Instance | denodo-poc-opendata-db | French OpenData |
| ALB | keycloak-alb | Load balancer |
| Lambda | denodo-permissions-api | Authorization API |
| API Gateway | denodo-auth-api | REST API endpoint |

### Post-Deployment

#### Access Keycloak Admin Consoles

```bash
# Get ALB DNS name
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names keycloak-alb \
  --region eu-west-3 \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

# Keycloak Provider Admin
echo "http://$ALB_DNS/auth/admin/master/console/#/denodo-idp"

# Keycloak Consumer Admin  
echo "http://$ALB_DNS/auth/admin/master/console/#/denodo-consumer"

# Admin credentials stored in Secrets Manager:
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/admin \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.password'
```

#### Test Users

| Username | Password | Profile | Datasources |
|----------|----------|---------|-------------|
| analyst@denodo.com | Analyst@2026! | data-analyst | rds-opendata, api-geo |
| scientist@denodo.com | Scientist@2026! | data-scientist | rds-opendata, api-geo, api-sirene |
| admin@denodo.com | Admin@2026! | admin | all |

#### Test Authorization API

```bash
# Get API endpoint
API_ENDPOINT=$(cat deployment-info.json | jq -r '.apiGatewayEndpoint')
API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id denodo-poc/api/auth-key \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.apiKey')

# Test permissions lookup
curl -H "X-API-Key: $API_KEY" \
  "$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions"
```

#### Connect Denodo to Data Sources

**RDS OpenData Connection:**
```sql
-- In Denodo Data Source configuration
Type: PostgreSQL
Host: <from deployment-info.json: rdsEndpoints.opendata>
Port: 5432
Database: opendata
Schema: opendata
Username: denodo
Password: <from Secrets Manager: denodo-poc/opendata/db>
```

**Public API Connection:**
```
Name: API_GEO_GOUV
Type: JSON/REST
Base URL: https://geo.api.gouv.fr
Authentication: None (public API)
```

### Testing

```bash
# Run comprehensive tests
./tests/test-all.sh

# Individual tests
./tests/test-authentication.sh    # Test OIDC flow
./tests/test-authorization.sh     # Test Lambda API
./tests/test-data-sources.sh      # Test RDS and API connectivity
```

### Monitoring

```bash
# View Keycloak Provider logs
aws logs tail /ecs/keycloak-provider --follow --region eu-west-3

# View Keycloak Consumer logs
aws logs tail /ecs/keycloak-consumer --follow --region eu-west-3

# View Lambda API logs
aws logs tail /aws/lambda/denodo-permissions-api --follow --region eu-west-3

# Check ECS service health
aws ecs describe-services \
  --cluster denodo-keycloak-cluster \
  --services keycloak-provider keycloak-consumer \
  --region eu-west-3 \
  --query 'services[].[serviceName,status,runningCount]' \
  --output table
```

### Cost Estimation

| Service | Monthly Cost |
|---------|--------------|
| ECS Fargate (2 tasks) | ~$35 |
| RDS (3 instances) | ~$65 |
| ALB | ~$22 |
| Lambda + API Gateway | ~$2 |
| Data Transfer | ~$1 |
| Secrets Manager | ~$3 |
| CloudWatch Logs | ~$2 |
| **Total** | **~$130/month** |

### Cleanup

```bash
# Delete all resources
./scripts/cleanup-all.sh

# Or delete manually
./scripts/delete-ecs.sh         # Delete ECS resources
./scripts/delete-rds.sh         # Delete RDS instances
./scripts/delete-lambda.sh      # Delete Lambda and API Gateway
./scripts/delete-network.sh     # Delete security groups
```

### Troubleshooting

#### Keycloak not accessible

```bash
# Check ECS tasks are running
aws ecs list-tasks --cluster denodo-keycloak-cluster --region eu-west-3

# Check ALB health checks
aws elbv2 describe-target-health \
  --target-group-arn <target-group-arn> \
  --region eu-west-3
```

#### OIDC Federation failing

```bash
# Verify client secret matches
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/client-secret \
  --region eu-west-3

# Check Keycloak Provider logs for authentication attempts
aws logs filter-log-events \
  --log-group-name /ecs/keycloak-provider \
  --filter-pattern "OIDC" \
  --region eu-west-3
```

#### Database connection errors

```bash
# Test database connectivity from ECS task
aws ecs execute-command \
  --cluster denodo-keycloak-cluster \
  --task <task-id> \
  --container keycloak \
  --command "pg_isready -h <db-endpoint> -p 5432" \
  --interactive \
  --region eu-west-3
```

### Data Sources

#### OpenData Tables

1. **entreprises** - 15,000+ French companies (SIRENE data)
2. **population_communes** - 36,000+ French communes with population

#### Sample Queries

```sql
-- Companies in Paris with population
SELECT 
    e.siren,
    e.nom_raison_sociale,
    e.ville,
    p.population
FROM opendata.entreprises e
LEFT JOIN opendata.population_communes p ON e.code_postal = p.code_postal
WHERE e.departement = '75'
ORDER BY p.population DESC
LIMIT 100;

-- Companies by sector and region
SELECT 
    e.libelle_naf as sector,
    e.departement,
    COUNT(*) as company_count
FROM opendata.entreprises e
WHERE e.statut = 'Actif'
GROUP BY e.libelle_naf, e.departement
ORDER BY company_count DESC;
```

### Support

For issues or questions:
1. Check logs in CloudWatch
2. Review deployment-info.json for configuration
3. Verify AWS resource status in Console
4. Run diagnostic scripts in `/tests`

### Documentation

- [Architecture Diagram](./docs/DENODO_KEYCLOAK_ARCHITECTURE.md)
- [Security Configuration](./docs/SECURITY.md)
- [API Reference](./docs/API_REFERENCE.md)
- [Data Sources Guide](./docs/DATA_SOURCES.md)

---

**Version:** 1.0  
**Last Updated:** February 5, 2026  
**Region:** eu-west-3 (Paris)  
**Maintainer:** Jaafar Benabderrazak
