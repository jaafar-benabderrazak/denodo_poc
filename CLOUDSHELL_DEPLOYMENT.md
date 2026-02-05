# Guide de Déploiement CloudShell - Denodo Keycloak POC

## 🚀 Déploiement Rapide

### 1. Initialisation dans CloudShell

```bash
# Cloner le repository
git clone https://github.com/jaafar-benabderrazak/denodo_poc.git

# Accéder au répertoire
cd denodo_poc

# Rendre les scripts exécutables
chmod +x scripts/*.sh
```

### 2. Vérifier les Prérequis

```bash
# Vérifier les outils installés
which aws     # ✓ AWS CLI
which jq      # ✓ JSON processor
which curl    # ✓ HTTP client
which psql    # ✓ PostgreSQL client
which python3 # ✓ Python 3 (pour génération SQL)

# Vérifier les credentials AWS
aws sts get-caller-identity

# Vérifier la région
aws configure get region
# Si pas configuré, définir la région:
aws configure set region eu-west-3
```

### 3. Lancer le Déploiement

```bash
# Option 1: Déploiement étape par étape avec validation (RECOMMANDÉ)
./scripts/deploy-step-by-step.sh

# Option 2: Déploiement automatique complet
./scripts/deploy-denodo-keycloak.sh
```

---

## 📊 Monitoring Pendant le Déploiement

### Ouvrir un 2ème onglet CloudShell

```bash
# Suivre les Security Groups créés
aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=denodo-poc" \
  --region eu-west-3 \
  --query 'SecurityGroups[].{Name:GroupName,ID:GroupId}' \
  --output table

# Suivre les instances RDS
watch -n 30 'aws rds describe-db-instances \
  --region eu-west-3 \
  --query "DBInstances[?contains(DBInstanceIdentifier, \`denodo-poc\`)].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Endpoint:Endpoint.Address}" \
  --output table'

# Suivre les secrets
aws secretsmanager list-secrets \
  --filters Key=name,Values=denodo-poc \
  --region eu-west-3 \
  --query 'SecretList[].{Name:Name,LastChanged:LastChangedDate}' \
  --output table
```

---

## 🔧 Commandes de Dépannage

### En cas d'erreur "Instance already exists"

```bash
# Vérifier l'état des instances RDS
aws rds describe-db-instances \
  --region eu-west-3 \
  --query 'DBInstances[?contains(DBInstanceIdentifier, `denodo-poc`)].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}' \
  --output table

# Supprimer les instances en erreur
aws rds delete-db-instance \
  --db-instance-identifier denodo-poc-keycloak-provider-db \
  --skip-final-snapshot \
  --region eu-west-3

aws rds delete-db-instance \
  --db-instance-identifier denodo-poc-keycloak-consumer-db \
  --skip-final-snapshot \
  --region eu-west-3

aws rds delete-db-instance \
  --db-instance-identifier denodo-poc-opendata-db \
  --skip-final-snapshot \
  --region eu-west-3

# Attendre que les instances soient supprimées (5-10 min)
aws rds wait db-instance-deleted \
  --db-instance-identifier denodo-poc-keycloak-provider-db \
  --region eu-west-3
```

### Nettoyer complètement toutes les ressources

```bash
# Script de nettoyage complet
cat > cleanup-all.sh <<'EOF'
#!/bin/bash
REGION="eu-west-3"
PROJECT="denodo-poc"

echo "🗑️  Suppression des instances RDS..."
for db in $(aws rds describe-db-instances --region $REGION --query "DBInstances[?contains(DBInstanceIdentifier, '$PROJECT')].DBInstanceIdentifier" --output text); do
  echo "  Suppression: $db"
  aws rds delete-db-instance --db-instance-identifier $db --skip-final-snapshot --region $REGION 2>/dev/null || true
done

echo "🗑️  Suppression du DB Subnet Group..."
aws rds delete-db-subnet-group --db-subnet-group-name ${PROJECT}-db-subnet-group --region $REGION 2>/dev/null || true

echo "🗑️  Suppression des Security Groups..."
for sg in $(aws ec2 describe-security-groups --filters "Name=tag:Project,Values=$PROJECT" --region $REGION --query 'SecurityGroups[].GroupId' --output text); do
  echo "  Suppression: $sg"
  aws ec2 delete-security-group --group-id $sg --region $REGION 2>/dev/null || true
done

echo "🗑️  Suppression des secrets..."
for secret in $(aws secretsmanager list-secrets --filters Key=name,Values=$PROJECT --region $REGION --query 'SecretList[].Name' --output text); do
  echo "  Suppression: $secret"
  aws secretsmanager delete-secret --secret-id $secret --force-delete-without-recovery --region $REGION 2>/dev/null || true
done

echo "✅ Nettoyage terminé!"
EOF

chmod +x cleanup-all.sh
./cleanup-all.sh
```

---

## 📁 Vérifier les Résultats

### Après le déploiement

```bash
# Voir le résumé du déploiement
cat deployment-info.json | jq '.'

# Récupérer les endpoints RDS
cat deployment-info.json | jq -r '.rdsEndpoints'

# Voir les secrets créés
cat deployment-info.json | jq -r '.secrets'

# Statistiques des données chargées
cat deployment-info.json | jq -r '.dataStats'
```

### Récupérer les mots de passe

```bash
# Mot de passe admin Keycloak
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/admin \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.password'

# Mot de passe base OpenData
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/opendata/db \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.password'

# API Key pour Lambda
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/api/auth-key \
  --region eu-west-3 \
  --query SecretString \
  --output text | jq -r '.apiKey'
```

### Tester la connexion à OpenData DB

```bash
# Récupérer les infos de connexion
OPENDATA_ENDPOINT=$(cat deployment-info.json | jq -r '.rdsEndpoints.opendata')
OPENDATA_PASSWORD=$(aws secretsmanager get-secret-value --secret-id denodo-poc/opendata/db --region eu-west-3 --query SecretString --output text | jq -r '.password')

# Se connecter à la base
export PGPASSWORD=$OPENDATA_PASSWORD
psql -h $OPENDATA_ENDPOINT -U denodo -d opendata -p 5432

# Dans psql:
# \dt opendata.*              -- Lister les tables
# SELECT COUNT(*) FROM opendata.entreprises;
# SELECT COUNT(*) FROM opendata.population_communes;
# \q                          -- Quitter
```

---

## ⏱️ Temps de Déploiement

| Phase | Durée | Description |
|-------|-------|-------------|
| Phase 0 | ~1 min | Vérification prérequis |
| Phase 1 | ~2 min | Security Groups |
| Phase 2 | ~1 min | Secrets Manager |
| Phase 3 | **10-15 min** | ⚠️ RDS Instances (le plus long) |
| Phase 4 | ~1 min | Schéma OpenData |
| Phase 5 | **5-10 min** | Chargement données (~36K communes + 1K entreprises) |
| Phase 6 | ~1 min | Sauvegarde config |
| **TOTAL** | **~30 min** | Avec pauses de validation |

---

## 🔍 Vérification de l'Infrastructure

### Après déploiement complet

```bash
# Résumé de toutes les ressources créées
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 RÉSUMÉ DE L'INFRASTRUCTURE DÉPLOYÉE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "🔒 Security Groups:"
aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=denodo-poc" \
  --region eu-west-3 \
  --query 'SecurityGroups[].{Name:GroupName,ID:GroupId}' \
  --output table

echo ""
echo "🗄️  Instances RDS:"
aws rds describe-db-instances \
  --region eu-west-3 \
  --query 'DBInstances[?contains(DBInstanceIdentifier, `denodo-poc`)].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Class:DBInstanceClass,Storage:AllocatedStorage}' \
  --output table

echo ""
echo "🔐 Secrets Manager:"
aws secretsmanager list-secrets \
  --filters Key=name,Values=denodo-poc \
  --region eu-west-3 \
  --query 'SecretList[].{Name:Name}' \
  --output table

echo ""
echo "📈 Données OpenData:"
OPENDATA_ENDPOINT=$(cat deployment-info.json | jq -r '.rdsEndpoints.opendata')
OPENDATA_PASSWORD=$(aws secretsmanager get-secret-value --secret-id denodo-poc/opendata/db --region eu-west-3 --query SecretString --output text | jq -r '.password')
export PGPASSWORD=$OPENDATA_PASSWORD
psql -h $OPENDATA_ENDPOINT -U denodo -d opendata -p 5432 -c "SELECT 'Entreprises' as table, COUNT(*) as count FROM opendata.entreprises UNION ALL SELECT 'Communes' as table, COUNT(*) as count FROM opendata.population_communes;" -t
unset PGPASSWORD

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

---

## 💰 Estimation des Coûts

```bash
# Calculer les coûts mensuels estimés
cat <<EOF
┌─────────────────────────────────────────────────────┐
│           ESTIMATION DES COÛTS MENSUELS             │
├─────────────────────────────────────────────────────┤
│ RDS PostgreSQL (3x db.t3.micro/small)    ~65€      │
│ Secrets Manager (6 secrets)               ~3€      │
│ Data Transfer                              ~1€      │
├─────────────────────────────────────────────────────┤
│ TOTAL (Phase 1 uniquement)               ~69€/mois │
│                                                     │
│ Note: Coûts additionnels si déploiement complet:   │
│ - ECS Fargate (2 tasks)                  ~35€      │
│ - Application Load Balancer              ~22€      │
│ - Lambda + API Gateway                    ~2€      │
│ - CloudWatch Logs                         ~2€      │
│                                                     │
│ TOTAL COMPLET                           ~130€/mois │
└─────────────────────────────────────────────────────┘
EOF
```

---

## 🆘 Support & Troubleshooting

### CloudShell timeout / Déconnexion

Si CloudShell se déconnecte pendant l'exécution:

```bash
# Reprendre là où vous étiez
cd denodo_poc

# Vérifier l'état actuel
cat deployment-info.json 2>/dev/null || echo "Pas encore de déploiement"

# Relancer le script - il détectera les ressources existantes
./scripts/deploy-step-by-step.sh
```

### Logs et Debugging

```bash
# Activer le mode debug
set -x
./scripts/deploy-step-by-step.sh

# Voir les logs AWS CloudTrail (dernière heure)
aws cloudtrail lookup-events \
  --region eu-west-3 \
  --lookup-attributes AttributeKey=ResourceType,AttributeValue=AWS::RDS::DBInstance \
  --max-results 10 \
  --query 'Events[].{Time:EventTime,Name:EventName,User:Username}' \
  --output table
```

### Problèmes de Permissions

```bash
# Vérifier vos permissions IAM
aws iam get-user
aws sts get-caller-identity

# Tester les permissions RDS
aws rds describe-db-instances --region eu-west-3 --max-records 1

# Tester les permissions EC2
aws ec2 describe-vpcs --region eu-west-3 --max-results 1

# Tester les permissions Secrets Manager
aws secretsmanager list-secrets --region eu-west-3 --max-results 1
```

---

## 📚 Fichiers Générés

Après le déploiement, vous aurez:

```bash
denodo_poc/
├── deployment-info.json          # Toutes les infos du déploiement
├── scripts/
│   ├── deploy-step-by-step.sh   # Script principal
│   └── deploy-denodo-keycloak.sh # Script automatique
├── sql/
│   └── 01-create-opendata-schema.sql
├── lambda/
│   └── permissions_api.py
├── config/
│   ├── keycloak-provider-task-definition.json
│   └── keycloak-consumer-task-definition.json
└── docs/
    └── DENODO_KEYCLOAK_ARCHITECTURE.md
```

---

## 🎯 Checklist de Déploiement

- [ ] CloudShell ouvert et région `eu-west-3` configurée
- [ ] Repository cloné et scripts exécutables
- [ ] Prérequis vérifiés (AWS CLI, jq, curl, psql)
- [ ] VPC `vpc-08ffb9d90f07533d0` existe
- [ ] Instance Denodo `i-0aef555dcb0ff873f` en cours d'exécution
- [ ] Pas d'instances RDS `denodo-poc-*` existantes en erreur
- [ ] Phase 0: Prérequis ✓
- [ ] Phase 1: Security Groups ✓
- [ ] Phase 2: Secrets Manager ✓
- [ ] Phase 3: RDS Instances ✓ (10-15 min)
- [ ] Phase 4: Schéma OpenData ✓
- [ ] Phase 5: Données chargées ✓ (5-10 min)
- [ ] Phase 6: deployment-info.json créé ✓
- [ ] Vérification: connexion PostgreSQL OK
- [ ] Vérification: données présentes (entreprises + communes)

---

## 📞 Contact

**Projet:** Denodo Keycloak POC  
**Maintainer:** Jaafar Benabderrazak  
**Repository:** https://github.com/jaafar-benabderrazak/denodo_poc  
**Date:** Février 2026
