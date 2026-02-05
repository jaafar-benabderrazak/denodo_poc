# Denodo Keycloak POC - Quick Reference Card

## 🚀 Quick Deploy

```bash
cd denodo-keycloak-poc
chmod +x scripts/*.sh
./scripts/deploy-denodo-keycloak.sh
```

**Time:** ~45 minutes | **Cost:** ~$130/month

---

## 📋 What Gets Deployed

✅ 2 Keycloak instances (Provider + Consumer) on ECS Fargate  
✅ 3 RDS PostgreSQL databases  
✅ Application Load Balancer  
✅ Lambda Authorization API  
✅ French OpenData (15k companies + 36k communes)  
✅ 6 Security Groups + Secrets Manager

---

## 🔑 Test Credentials

| User | Email | Password | Profile |
|------|-------|----------|---------|
| Analyst | analyst@denodo.com | Analyst@2026! | Read/Query |
| Scientist | scientist@denodo.com | Scientist@2026! | Read/Query/Export |
| Admin | admin@denodo.com | Admin@2026! | Full Access |

---

## 🌐 URLs (After Deployment)

```bash
# Get ALB DNS
ALB=$(aws elbv2 describe-load-balancers --names keycloak-alb --region eu-west-3 --query 'LoadBalancers[0].DNSName' --output text)

# Keycloak Provider: http://$ALB/auth/realms/denodo-idp
# Keycloak Consumer: http://$ALB/auth/realms/denodo-consumer
# Admin Console: http://$ALB/auth/admin
```

---

## 💾 Data Sources

**RDS OpenData**
```sql
Host: (see deployment-info.json)
Database: opendata
Tables: entreprises, population_communes
Views: entreprises_population, stats_departement
```

**Public API**
```
https://geo.api.gouv.fr/communes
https://geo.api.gouv.fr/departements
https://geo.api.gouv.fr/regions
```

---

## 🔐 Get Secrets

```bash
# Admin password
aws secretsmanager get-secret-value --secret-id denodo-poc/keycloak/admin --region eu-west-3 --query SecretString --output text | jq -r '.password'

# OpenData DB password
aws secretsmanager get-secret-value --secret-id denodo-poc/opendata/db --region eu-west-3 --query SecretString --output text | jq -r '.password'

# API Key
aws secretsmanager get-secret-value --secret-id denodo-poc/api/auth-key --region eu-west-3 --query SecretString --output text | jq -r '.apiKey'
```

---

## 📊 Monitor

```bash
# ECS Services Status
aws ecs describe-services --cluster denodo-keycloak-cluster --services keycloak-provider keycloak-consumer --region eu-west-3 --query 'services[].[serviceName,status,runningCount]' --output table

# View Logs
aws logs tail /ecs/keycloak-provider --follow --region eu-west-3
aws logs tail /ecs/keycloak-consumer --follow --region eu-west-3

# RDS Status
aws rds describe-db-instances --region eu-west-3 --query 'DBInstances[?contains(DBInstanceIdentifier,`denodo-poc`)].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}' --output table
```

---

## 🧪 Test Commands

```bash
# Test Keycloak Health
curl http://$ALB/auth/health/ready

# Test Authorization API
curl -H "X-API-Key: YOUR_KEY" "$API_ENDPOINT/api/v1/users/analyst@denodo.com/permissions"

# Test Database
psql -h $DB_HOST -U denodo -d opendata -c "SELECT COUNT(*) FROM opendata.entreprises;"
```

---

## 🗑️ Cleanup

```bash
# Delete all resources
./scripts/cleanup-all.sh

# Or selective
aws rds delete-db-instance --db-instance-identifier denodo-poc-keycloak-provider-db --skip-final-snapshot --region eu-west-3
aws ecs delete-cluster --cluster denodo-keycloak-cluster --region eu-west-3
```

---

## 📁 Project Structure

```
denodo-keycloak-poc/
├── README.md              # Main documentation
├── PROJECT_SUMMARY.md     # Complete project overview
├── QUICK_REFERENCE.md     # This file
├── scripts/
│   └── deploy-denodo-keycloak.sh (850 lines)
├── config/
│   ├── keycloak-provider-task-definition.json
│   └── keycloak-consumer-task-definition.json
├── sql/
│   └── 01-create-opendata-schema.sql (500+ lines)
├── lambda/
│   └── permissions_api.py (350+ lines)
└── docs/
    └── DENODO_KEYCLOAK_ARCHITECTURE.md (with Mermaid diagrams)
```

---

## 🆘 Troubleshooting

| Issue | Solution |
|-------|----------|
| VPC not found | Check VPC ID: vpc-08ffb9d90f07533d0 |
| Not enough subnets | Need 2+ private & 2+ public subnets |
| RDS taking too long | Wait 10-15 min for RDS availability |
| Keycloak not accessible | Check ALB health checks & security groups |
| Auth failing | Verify client secret matches in both Keycloaks |

---

## 📞 Key Info

**Region:** eu-west-3  
**VPC:** vpc-08ffb9d90f07533d0  
**Account:** 928902064673  
**Denodo EC2:** 10.0.75.195

**Creator:** Jaafar Benabderrazak  
**Date:** Feb 5, 2026  
**Version:** 1.0
