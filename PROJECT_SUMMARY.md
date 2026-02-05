# Denodo Keycloak POC - Project Summary

## Project Overview

Complete Keycloak federation infrastructure for Denodo data virtualization with French OpenData integration.

**Creation Date:** February 5, 2026  
**Status:** Ready for Deployment  
**Region:** eu-west-3 (Paris)  
**Estimated Deploy Time:** 45 minutes  
**Monthly Cost:** ~$130

---

## Project Structure

```
denodo-keycloak-poc/
├── README.md                          # Main documentation and quick start
├── scripts/
│   └── deploy-denodo-keycloak.sh     # Main CloudShell deployment script
├── config/
│   ├── keycloak-provider-task-definition.json
│   └── keycloak-consumer-task-definition.json
├── sql/
│   └── 01-create-opendata-schema.sql # OpenData database schema
├── lambda/
│   └── permissions_api.py            # Authorization API Lambda function
├── docs/
│   └── DENODO_KEYCLOAK_ARCHITECTURE.md  # Complete architecture documentation
└── tests/
    └── (test scripts to be added)
```

---

## What This Project Deploys

### Infrastructure Components

1. **Keycloak Provider (Identity Provider)**
   - ECS Fargate service
   - Realm: denodo-idp
   - RDS PostgreSQL database
   - Manages user identities

2. **Keycloak Consumer (Service Provider)**
   - ECS Fargate service
   - Realm: denodo-consumer
   - RDS PostgreSQL database
   - Federates with Provider via OIDC

3. **OpenData Database**
   - RDS PostgreSQL (50GB)
   - French SIRENE companies (~15,000 records)
   - French communes population (~36,000 records)
   - Ready-to-use views and functions

4. **Authorization API**
   - Lambda function (Python 3.11)
   - API Gateway REST endpoint
   - Returns user datasource permissions

5. **Networking**
   - Application Load Balancer
   - 6 Security Groups
   - VPC integration with existing infrastructure

---

## Key Features

### OIDC Federation
- Automatic token exchange between Keycloak instances
- Custom JWT claims (profiles, datasources, roles)
- SSO capability for Denodo users

### Data Sources

**Source 1: RDS PostgreSQL OpenData**
- Table: `entreprises` (French companies)
- Table: `population_communes` (City populations)
- View: `entreprises_population` (joined data)
- View: `stats_departement` (statistics)
- Function: `search_entreprises()` (advanced search)

**Source 2: Public API (geo.api.gouv.fr)**
- Communes data
- Departments
- Regions
- No authentication required

### User Profiles

**Data Analyst**
- Read/Query on OpenData + Geo API
- Max 10,000 rows per query
- No export capability

**Data Scientist**
- Read/Query/Export on all sources
- Max 50,000 rows per query
- Can create views
- Access to additional SIRENE API

**Administrator**
- Full access to all datasources
- Unlimited queries
- User and datasource management

---

## Deployment Instructions

### Prerequisites
```bash
# Tools needed
- AWS CLI v2+
- jq
- curl
- openssl (for password generation)

# AWS Account
- Account: 928902064673
- Region: eu-west-3
- VPC: vpc-08ffb9d90f07533d0 must exist
```

### Quick Deploy (CloudShell)

```bash
# 1. Upload project folder to CloudShell
# 2. Navigate to project
cd denodo-keycloak-poc

# 3. Make scripts executable
chmod +x scripts/*.sh

# 4. Run deployment
./scripts/deploy-denodo-keycloak.sh
```

### Deployment Phases

The script creates infrastructure in phases:

**Phase 1: Prerequisites** (2 min)
- Validates AWS CLI
- Checks VPC and subnets
- Discovers network configuration

**Phase 2: Security Groups** (2 min)
- Creates 6 security groups
- Configures ingress/egress rules
- Updates Denodo EC2 security group

**Phase 3: Secrets** (1 min)
- Generates secure passwords
- Creates 6 secrets in Secrets Manager
- Stores database credentials, API keys

**Phase 4: RDS Databases** (15-20 min)
- Creates 3 PostgreSQL instances
- Waits for availability
- Updates secrets with endpoints

**Next Steps** (manual or scripted):
- Create ECS cluster
- Deploy Keycloak services
- Load OpenData
- Configure OIDC federation
- Deploy Lambda API

---

## Files Created

### Documentation (1 file)
- `docs/DENODO_KEYCLOAK_ARCHITECTURE.md` - Complete architecture with Mermaid diagrams

### Scripts (1 file)
- `scripts/deploy-denodo-keycloak.sh` - CloudShell deployment (850 lines)

### Configuration (2 files)
- `config/keycloak-provider-task-definition.json` - ECS task for Provider
- `config/keycloak-consumer-task-definition.json` - ECS task for Consumer

### SQL (1 file)
- `sql/01-create-opendata-schema.sql` - Complete database schema (500+ lines)

### Lambda (1 file)
- `lambda/permissions_api.py` - Authorization API (350+ lines)

### Project Files (2 files)
- `README.md` - Quick start and usage guide
- `PROJECT_SUMMARY.md` - This file

**Total: 8 files created**

---

## AWS Resources Created by Script

| Resource Type | Count | Purpose |
|---------------|-------|---------|
| Security Groups | 6 | Network security |
| RDS Instances | 3 | Keycloak + OpenData databases |
| Secrets | 6 | Secure credential storage |
| DB Subnet Group | 1 | RDS networking |

**Additional resources to be created:**
- 1 ECS Cluster
- 2 ECS Services
- 1 Application Load Balancer
- 2 Target Groups
- 1 Lambda Function
- 1 API Gateway
- 3 CloudWatch Log Groups

---

## Configuration Details

### VPC Configuration
- **VPC ID:** vpc-08ffb9d90f07533d0
- **Private Subnets:** Auto-discovered (minimum 2 required)
- **Public Subnets:** Auto-discovered (minimum 2 required)
- **Denodo EC2:** 10.0.75.195 (will be granted access)

### Keycloak Configuration
- **Image:** quay.io/keycloak/keycloak:23.0
- **CPU:** 512 (0.5 vCPU)
- **Memory:** 1024 MB
- **Health Check:** /health/ready endpoint
- **Startup Time:** ~5 minutes

### Database Configuration
- **Engine:** PostgreSQL 15.4
- **Provider/Consumer:** db.t3.micro (20 GB)
- **OpenData:** db.t3.small (50 GB)
- **Backup:** 7 days retention
- **Multi-AZ:** Disabled (POC)

### Security
- All databases in private subnets
- No public access to databases
- Passwords auto-generated (32 characters)
- Credentials stored in Secrets Manager
- Security groups follow least-privilege

---

## Post-Deployment Tasks

### 1. Access Keycloak Admin Console

```bash
# Get admin password
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/admin \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.password'

# Get ALB DNS
aws elbv2 describe-load-balancers \
  --names keycloak-alb \
  --region eu-west-3 \
  --query 'LoadBalancers[0].DNSName' \
  --output text

# Access: http://{ALB_DNS}/auth/admin
```

### 2. Configure Denodo Data Sources

**RDS OpenData:**
```
Type: PostgreSQL
Host: (from deployment-info.json: rdsEndpoints.opendata)
Port: 5432
Database: opendata
Schema: opendata
Username: denodo
Password: (from Secrets Manager: denodo-poc/opendata/db)
```

**Public API:**
```
Name: GEO_API_GOUV
Type: JSON/REST
Base URL: https://geo.api.gouv.fr
Authentication: None
```

### 3. Test Authentication

```bash
# Test Provider login
curl http://{ALB_DNS}/auth/realms/denodo-idp/account

# Test Consumer login
curl http://{ALB_DNS}/auth/realms/denodo-consumer/account

# Test OIDC federation
# (Manual test via browser)
```

### 4. Test Authorization API

```bash
# Get API key
API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id denodo-poc/api/auth-key \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.apiKey')

# Test permissions lookup
curl -H "X-API-Key: $API_KEY" \
  "{API_GATEWAY_URL}/api/v1/users/analyst@denodo.com/permissions"
```

---

## Monitoring & Operations

### View Logs

```bash
# Keycloak Provider
aws logs tail /ecs/keycloak-provider --follow --region eu-west-3

# Keycloak Consumer
aws logs tail /ecs/keycloak-consumer --follow --region eu-west-3

# Lambda API
aws logs tail /aws/lambda/denodo-permissions-api --follow --region eu-west-3
```

### Check Health

```bash
# ECS Services
aws ecs describe-services \
  --cluster denodo-keycloak-cluster \
  --services keycloak-provider keycloak-consumer \
  --region eu-west-3 \
  --query 'services[].[serviceName,status,runningCount,desiredCount]' \
  --output table

# RDS Status
aws rds describe-db-instances \
  --region eu-west-3 \
  --query 'DBInstances[?contains(DBInstanceIdentifier, `denodo-poc`)].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Endpoint:Endpoint.Address}' \
  --output table
```

---

## Cost Breakdown

| Service | Configuration | Monthly Cost |
|---------|---------------|--------------|
| ECS Fargate | 2 tasks × 0.5 vCPU × 730h | $35 |
| RDS (Keycloak) | 2 × db.t3.micro × 730h | $30 |
| RDS (OpenData) | 1 × db.t3.small × 730h | $35 |
| ALB | 1 × 730h + LCU | $22 |
| Lambda | 100k requests | <$1 |
| API Gateway | 100k requests | $1 |
| Secrets Manager | 6 secrets | $3 |
| CloudWatch | 5 GB logs | $3 |
| **Total** | | **~$130/month** |

---

## Troubleshooting

### Issue: Script fails at VPC validation
**Solution:** Ensure VPC vpc-08ffb9d90f07533d0 exists in eu-west-3

### Issue: Not enough subnets
**Solution:** VPC must have minimum 2 private + 2 public subnets in different AZs

### Issue: AWS credentials error
**Solution:** Run `aws configure` or use CloudShell

### Issue: Permission denied
**Solution:** IAM user needs EC2, ECS, RDS, Secrets Manager, IAM permissions

---

## Next Steps

After infrastructure deployment:

1. **Complete ECS Setup** - Deploy Keycloak services
2. **Load OpenData** - Populate database with sample data
3. **Configure Federation** - Set up OIDC between Keycloak instances
4. **Deploy Lambda** - Create authorization API
5. **Test Integration** - Verify Denodo can access all components
6. **Create Documentation** - Document specific use cases

---

## Support & Maintenance

### Backup Strategy
- RDS automated backups: 7 days
- Secrets stored in Secrets Manager (versioned)
- deployment-info.json: Save for future reference

### Updates
- Keycloak: Update image tag in task definition
- RDS: Apply updates during maintenance window
- Lambda: Update function code via AWS Console or CLI

### Cleanup
```bash
# To delete all resources (when POC is complete)
./scripts/cleanup-all.sh

# Or selective cleanup
./scripts/delete-ecs.sh        # ECS only
./scripts/delete-rds.sh        # RDS only
./scripts/delete-network.sh    # Security groups only
```

---

## Contact & References

**Created by:** Jaafar Benabderrazak  
**Date:** February 5, 2026  
**Region:** eu-west-3 (Paris)  
**Account:** 928902064673

**Related Projects:**
- CA-A2A (parent directory): Keycloak ECS deployment reference
- EU-WEST-3 Deletion: Resource cleanup procedures

**External References:**
- Keycloak Documentation: https://www.keycloak.org/docs/latest/
- French OpenData: https://www.data.gouv.fr/
- Geo API: https://geo.api.gouv.fr/

---

**Status:** ✅ Ready for Deployment  
**Version:** 1.0  
**Last Updated:** February 5, 2026
