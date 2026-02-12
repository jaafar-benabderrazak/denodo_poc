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
- python3 (for SQL generation)
- PostgreSQL client (psql) - required for data loading

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

#### Option 1: Déploiement Étape par Étape avec Validation (Recommandé)

```bash
# Upload this folder to CloudShell
cd denodo-keycloak-poc

# Make script executable
chmod +x scripts/*.sh

# Run step-by-step deployment with validation pauses
./scripts/deploy-step-by-step.sh
```

**Avantages:**
- ✓ Validation manuelle après chaque phase
- ✓ Alimentation automatique des données OpenData (~36,000 communes + 1,000 entreprises)
- ✓ Messages colorés et progression claire
- ✓ Possibilité d'arrêter à tout moment

**Phases couvertes:**
1. Phase 0: Vérification des prérequis (AWS CLI, VPC, credentials)
2. Phase 1: Création des Security Groups (ALB, ECS, RDS)
3. Phase 2: Génération et stockage des secrets (Secrets Manager)
4. Phase 3: Création des 3 bases RDS PostgreSQL (10-15 min)
5. Phase 4: Initialisation du schéma OpenData
6. Phase 5: Alimentation des données (communes + entreprises)
7. Phase 6: Sauvegarde des informations de déploiement

**Time:** ~30 minutes avec pauses de validation

#### Option 2: Déploiement Automatique Complet

```bash
# Infrastructure complète sans pauses
./scripts/deploy-denodo-keycloak.sh
```

**Time:** ~20 minutes (sans alimentation des données)

#### Option 3: Déploiement Manuel Phase par Phase

```bash
# Phase 1: Infrastructure
./scripts/deploy-denodo-keycloak.sh

# Phase 2: ECS Cluster & Keycloak
./scripts/deploy-ecs-keycloak.sh

# Phase 2.5: Load OpenData schema + sample data
./scripts/load-opendata.sh

# Phase 3: Configure OIDC Federation
./scripts/configure-keycloak.sh

# Phase 4: Deploy Lambda API
./scripts/deploy-lambda-api.sh
```

#### Option 4: Déploiement Complet (enchaîné)

```bash
./scripts/deploy-all.sh
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

### Post-Deployment: Complete Setup and Verify

After deploying the base infrastructure, run the all-in-one setup and verification:

```bash
# Fix ALB routing, deploy API Gateway, verify all components
chmod +x scripts/*.sh
./scripts/complete-setup.sh

# Run full automated test suite (6 categories)
./scripts/verify-all.sh
```

#### Access Keycloak Admin Console

```
URL:      http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/admin
Username: admin
Password: (from Secrets Manager: denodo-poc/keycloak/admin)
```

#### Test Users (denodo-idp realm)

| Username | Password | Profile | Datasources | Max Rows |
|----------|----------|---------|-------------|----------|
| analyst@denodo.com | Analyst@2026! | data-analyst | rds-opendata, api-geo | 10,000 |
| scientist@denodo.com | Scientist@2026! | data-scientist | rds-opendata, api-geo, api-sirene | 100,000 |
| admin@denodo.com | Admin@2026! | admin | all | unlimited |

#### Test Authorization API

```bash
curl -H "X-API-Key: <API_KEY>" \
  "https://9q5f8cjxe9.execute-api.eu-west-3.amazonaws.com/dev/api/v1/users/analyst@denodo.com/permissions"
```

#### Connect Denodo to Data Sources

**OIDC Authentication:**
```
Issuer:        http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-consumer
Client ID:     denodo-consumer
Client Secret: (from Secrets Manager: denodo-poc/keycloak/client-secret)
Scopes:        openid email profile
```

**RDS OpenData Connection:**
```
Type:     PostgreSQL
Host:     denodo-poc-opendata-db.cacjdkje8yxa.eu-west-3.rds.amazonaws.com
Port:     5432
Database: opendata
Schema:   opendata
Username: denodo
Password: (from Secrets Manager: denodo-poc/opendata/db)
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
# Full verification (API, Keycloak, OIDC, Federation, RDS)
./scripts/verify-all.sh

# Individual test suites
./tests/test-all.sh               # Orchestrated test runner
./tests/test-authentication.sh    # OIDC token grants
./tests/test-authorization.sh     # Lambda API permissions
./tests/test-data-sources.sh      # RDS and API connectivity
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

- [Deployment Status](./docs/DEPLOYMENT_STATUS.md) -- current status, what is deployed, what remains
- [Showcase Scenarios](./docs/SHOWCASE_SCENARIOS.md) -- 10 step-by-step demo scenarios with Mermaid diagrams
- [Architecture Diagram](./docs/DENODO_KEYCLOAK_ARCHITECTURE.md) -- full technical architecture
- [Project Summary](./PROJECT_SUMMARY.md)
- [Quick Reference](./QUICK_REFERENCE.md)
- [Testing Guide](./TESTING_GUIDE.md)

---

**Version:** 2.0
**Last Updated:** 12 February 2026
**Region:** eu-west-3 (Paris)
**Maintainer:** Jaafar Benabderrazak
