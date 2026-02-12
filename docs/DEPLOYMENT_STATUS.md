# Denodo Keycloak POC -- Deployment Status

**Date:** 12 February 2026
**Region:** eu-west-3 (Paris)
**Account:** 928902064673
**Author:** Jaafar Benabderrazak

> **📋 Document Purpose:**
> This document describes the **actual deployed architecture** of the Denodo Keycloak POC, including implementation decisions and workarounds made during deployment. Some aspects differ from the original architecture plan (see [DENODO_KEYCLOAK_ARCHITECTURE.md](./DENODO_KEYCLOAK_ARCHITECTURE.md)) due to deployment constraints, cost optimization, and POC simplification.

---

## Deployment Progress

```mermaid
pie title "Deployment Completion (12 Feb 2026)"
    "Infrastructure & Tests: COMPLETE" : 100
```

**Status:** All 28 automated tests passed. Infrastructure is 100% operational and ready for Denodo platform integration.

---

## 1. Overall Architecture (As Deployed)

```mermaid
graph TB
    subgraph "Internet / User"
        USER["User / Browser"]
        CLOUDSHELL["AWS CloudShell"]
    end

    subgraph "AWS VPC -- eu-west-3 (ADS VPC)"
        subgraph "Public Subnets (3a, 3b)"
            ALB["ALB: keycloak-alb\nPort 80 HTTP Only\nDNS: keycloak-alb-541762229.eu-west-3.elb.amazonaws.com"]
        end

        subgraph "ECS Fargate (Public Subnets, assignPublicIp=ENABLED)"
            KC_PROV["Keycloak Instance (ACTIVE)\n512 CPU / 1 GB RAM\nkeycloak:23.0.7\nHosts BOTH Realms:\n- master\n- denodo-idp (Provider)\n- denodo-consumer (Consumer)"]
            KC_CONS["Keycloak Consumer Service\n512 CPU / 1 GB RAM\nSTANDBY - No ALB routing"]
        end

        subgraph "Private Subnets -- Data Layer"
            RDS_P[("Provider DB\ndb.t3.micro\nPostgreSQL 15\nDatabase: postgres")]
            RDS_C[("Consumer DB\ndb.t3.micro\nPostgreSQL 15\nDatabase: postgres")]
            RDS_O[("OpenData DB\ndb.t3.small\nPostgreSQL 15\nDatabase: opendata\nSchema: opendata")]
        end

        subgraph "Serverless"
            APIGW["API Gateway\ndenodo-auth-api\nhttps://9q5f8cjxe9.execute-api.eu-west-3.amazonaws.com/dev"]
            LAMBDA["Lambda\ndenodo-permissions-api\nPython 3.11\n256 MB"]
        end

        subgraph "Private Subnet (3c)"
            DENODO["Denodo EC2\ni-0aef555dcb0ff873f\nm5a.4xlarge\nSSM Online\n10.0.75.195"]
        end
    end

    subgraph "External Data Sources"
        GEO["geo.api.gouv.fr\nFrench Geographic Data\nACTIVELY USED"]
        SIRENE["entreprise.data.gouv.fr\nSIRENE Company Data\nOPTIONAL/NOT CONFIGURED"]
    end

    USER --> ALB
    USER --> APIGW
    CLOUDSHELL -.->|"SSM send-command"| DENODO

    ALB -->|"ALL /auth/* traffic"| KC_PROV
    ALB -.->|"NO TRAFFIC"| KC_CONS

    KC_PROV -->|"JDBC Connection"| RDS_P
    KC_CONS -->|"Not in use"| RDS_C
    DENODO -->|"PostgreSQL queries"| RDS_O
    DENODO -->|"REST API calls"| GEO
    DENODO -.->|"Future integration"| SIRENE

    APIGW --> LAMBDA

    style KC_PROV fill:#27ae60,color:#fff
    style KC_CONS fill:#95a5a6,color:#fff
    style ALB fill:#2980b9,color:#fff
    style LAMBDA fill:#8e44ad,color:#fff
    style APIGW fill:#8e44ad,color:#fff
    style DENODO fill:#e74c3c,color:#fff
    style RDS_O fill:#27ae60,color:#fff
    style RDS_P fill:#27ae60,color:#fff
    style RDS_C fill:#95a5a6,color:#fff
    style GEO fill:#f39c12,color:#000
    style SIRENE fill:#95a5a6,color:#fff
```

> **Important Deployment Details:**
> - **Single Keycloak Instance:** Both realms (`denodo-idp` and `denodo-consumer`) run on the same Keycloak Provider ECS task
> - **ALB Routing:** ALL traffic routes to Provider target group; Consumer service is standby only
> - **Network Configuration:** ECS tasks deployed in PUBLIC subnets with assignPublicIp=ENABLED (no NAT Gateway)
> - **Protocol:** HTTP only (Port 80), sslRequired=NONE due to no ACM certificate
> - **Database Names:** Using default `postgres` database (not custom database names)
> - **OIDC Federation:** Internal federation between denodo-consumer realm → denodo-idp realm on same instance

---

## 2. Deployed AWS Resources

```mermaid
flowchart LR
    subgraph "Infrastructure"
        VPC["VPC\nvpc-08ffb9d90f07533d0\nCIDR 10.0.0.0/16"]
        SG["Security Groups\n6 groups"]
    end

    subgraph "Compute"
        ECS["ECS Cluster\ndenodo-keycloak-cluster"]
        PROV_SVC["keycloak-provider\n1/1 tasks ACTIVE"]
        CONS_SVC["keycloak-consumer\n1/1 tasks ACTIVE"]
        EC2["Denodo EC2\nm5a.4xlarge"]
    end

    subgraph "Data"
        RDS1["RDS: keycloak-provider-db\ndb.t3.micro"]
        RDS2["RDS: keycloak-consumer-db\ndb.t3.micro"]
        RDS3["RDS: denodo-poc-opendata-db\ndb.t3.small\nSchema: opendata"]
    end

    subgraph "Application"
        ALB2["ALB: keycloak-alb\nactive"]
        LAMBDA2["Lambda: denodo-permissions-api\nActive"]
        APIGW2["API Gateway: denodo-auth-api\n9q5f8cjxe9"]
    end

    subgraph "Secrets"
        SM["Secrets Manager\n6 secrets stored"]
    end

    VPC --> SG --> ECS
    ECS --> PROV_SVC
    ECS --> CONS_SVC

    style VPC fill:#2ecc71,color:#fff
    style SG fill:#2ecc71,color:#fff
    style ECS fill:#2ecc71,color:#fff
    style PROV_SVC fill:#2ecc71,color:#fff
    style CONS_SVC fill:#2ecc71,color:#fff
    style EC2 fill:#2ecc71,color:#fff
    style RDS1 fill:#2ecc71,color:#fff
    style RDS2 fill:#2ecc71,color:#fff
    style RDS3 fill:#2ecc71,color:#fff
    style ALB2 fill:#2ecc71,color:#fff
    style LAMBDA2 fill:#2ecc71,color:#fff
    style APIGW2 fill:#2ecc71,color:#fff
    style SM fill:#2ecc71,color:#fff
```

| Component | Resource | Status | Identifier / Endpoint | Notes |
|-----------|----------|--------|----------------------|-------|
| **VPC** | ADS VPC | Active | `vpc-08ffb9d90f07533d0` (CIDR 10.0.0.0/16) | Existing VPC |
| **ECS Cluster** | denodo-keycloak-cluster | Active | Fargate launch type | 2 services |
| **ECS Service** | keycloak-provider | 1/1 tasks | ACTIVE | Hosts all 3 Keycloak realms, receives ALL ALB traffic |
| **ECS Service** | keycloak-consumer | 1/1 tasks | STANDBY | Running but not receiving traffic |
| **RDS** | keycloak-provider-db | Available | db.t3.micro, PostgreSQL 15 | Database: `postgres` (not custom name) |
| **RDS** | keycloak-consumer-db | Available | db.t3.micro, PostgreSQL 15 | Database: `postgres`, not actively used |
| **RDS** | denodo-poc-opendata-db | Available | db.t3.small, PostgreSQL 15 | Database: `opendata`, Schema: `opendata` |
| **ALB** | keycloak-alb | Active | `keycloak-alb-541762229.eu-west-3.elb.amazonaws.com` | HTTP only (Port 80), no HTTPS |
| **Lambda** | denodo-permissions-api | Active | Python 3.11, 256 MB | Role-based access control API |
| **API Gateway** | denodo-auth-api | Deployed | `https://9q5f8cjxe9.execute-api.eu-west-3.amazonaws.com/dev` | Requires X-API-Key header |
| **Secrets** | 6 secrets | Stored | Keycloak admin, DB passwords, client secret, API key | All in Secrets Manager |
| **Denodo EC2** | i-0aef555dcb0ff873f | Running | m5a.4xlarge, SSM Online, 10.0.75.195 | Used for RDS access via SSM |

---

## 3. ALB Routing Rules

```mermaid
flowchart TD
    REQ["Incoming HTTP Request\nPort 80"] --> LISTENER["ALB Listener"]

    LISTENER --> R10{"Path: /auth/realms/denodo-idp/*\nPriority 10"}
    R10 -->|Yes| TG["Provider TG"]
    R10 -->|No| R12{"Path: /auth/realms/master/*\nPriority 12"}

    R12 -->|Yes| TG
    R12 -->|No| R15{"Path: /auth/admin/*\nPriority 15"}

    R15 -->|Yes| TG
    R15 -->|No| R20{"Path: /auth/realms/denodo-consumer/*\nPriority 20"}

    R20 -->|Yes| TG
    R20 -->|No| R30{"Path: /auth/health/*\nPriority 30"}

    R30 -->|Yes| TG
    R30 -->|No| R99{"Path: /auth/*\nPriority 99\n(catch-all for JS/CSS)"}

    R99 -->|Yes| TG
    R99 -->|No| DEFAULT["404 Not Found"]

    style TG fill:#27ae60,color:#fff
    style DEFAULT fill:#e74c3c,color:#fff
    style R99 fill:#f39c12,color:#000
```

> The **Priority 99 catch-all** rule was added to fix the Keycloak admin UI "Loading" issue by ensuring static assets (JS, CSS, images) under `/auth/*` are forwarded to the Provider target group.

---

## 4. Keycloak Configuration

### Realms and Federation

```mermaid
graph TB
    subgraph "Single Keycloak Instance (Provider ECS Service)"
        subgraph "master realm"
            MASTER["Admin Console\nUsername: admin\nsslRequired: NONE\nPort: 8080"]
        end

        subgraph "denodo-idp realm (Identity Provider)"
            CLIENT["OIDC Client: denodo-consumer\nType: confidential\nProtocol: openid-connect\nSecret: stored in Secrets Manager"]

            subgraph "User Attributes & Mappers"
                MAPPER1["profiles mapper\n→ JWT claim: profiles"]
                MAPPER2["datasources mapper\n→ JWT claim: datasources"]
                MAPPER3["department mapper\n→ JWT claim: department"]
            end

            subgraph "Test Users"
                U1["analyst@denodo.com\nPassword: Analyst@2026!\nAttributes:\n- profiles: data-analyst\n- datasources: rds-opendata, api-geo\n- department: Analytics"]
                U2["scientist@denodo.com\nPassword: Scientist@2026!\nAttributes:\n- profiles: data-scientist\n- datasources: rds-opendata, api-geo, api-sirene\n- department: Research"]
                U3["admin@denodo.com\nPassword: Admin@2026!\nAttributes:\n- profiles: admin\n- datasources: *\n- department: IT"]
            end
        end

        subgraph "denodo-consumer realm (Service Provider)"
            IDP["Identity Provider Config: provider-idp\nType: OIDC\nEnabled: true\nInternal Brokering"]
            DC_CLIENT["Client: denodo-data-catalog\n(for Denodo platform)"]
        end
    end

    IDP -.->|"OIDC Federation Flow\n(internal to same instance)"| CLIENT
    DC_CLIENT -->|"Uses for authentication"| IDP

    style MASTER fill:#e67e22,color:#fff
    style CLIENT fill:#3498db,color:#fff
    style IDP fill:#9b59b6,color:#fff
    style DC_CLIENT fill:#2ecc71,color:#fff
    style U1 fill:#ecf0f1,color:#000
    style U2 fill:#ecf0f1,color:#000
    style U3 fill:#ecf0f1,color:#000
```

> **Key Configuration Details:**
> - All three realms (master, denodo-idp, denodo-consumer) run on a **single Keycloak instance**
> - The federation is **internal**: consumer realm → provider realm on same server
> - JWT tokens include custom claims (profiles, datasources, department) via attribute mappers
> - HTTP only (Port 80) - sslRequired disabled on all realms for POC
> - Consumer ECS service exists but is not used (all traffic goes to Provider service)

### OIDC Federation Flow

```mermaid
sequenceDiagram
    participant User
    participant Denodo as Denodo Platform
    participant Consumer as Consumer Realm
    participant Provider as Provider Realm (IdP)
    participant DB as Provider DB

    User->>Denodo: 1. Access data view
    Denodo->>Consumer: 2. Redirect to /auth/realms/denodo-consumer
    Consumer->>User: 3. Show login page with "Sign in with provider-idp"
    User->>Consumer: 4. Click provider-idp
    Consumer->>Provider: 5. OIDC Authorization Request
    Provider->>User: 6. Show provider login form
    User->>Provider: 7. Enter credentials (analyst@denodo.com)
    Provider->>DB: 8. Validate user
    DB-->>Provider: 9. User valid
    Provider->>Provider: 10. Generate JWT (profiles, roles, datasources)
    Provider-->>Consumer: 11. Authorization code
    Consumer->>Provider: 12. Exchange code for tokens
    Provider-->>Consumer: 13. Access Token + ID Token
    Consumer->>Consumer: 14. Map claims (profiles, datasources, department)
    Consumer-->>Denodo: 15. JWT with mapped claims
    Denodo->>Denodo: 16. Extract permissions from JWT
    Denodo-->>User: 17. Data access granted
```

### Authorization API Flow

```mermaid
sequenceDiagram
    participant Denodo
    participant APIGW as API Gateway
    participant Lambda as Lambda Function
    participant SM as Secrets Manager

    Denodo->>APIGW: GET /api/v1/users/{email}/permissions
    Note over APIGW: Header: X-API-Key required
    APIGW->>APIGW: Validate API Key
    APIGW->>Lambda: Invoke (AWS_PROXY)
    Lambda->>Lambda: Lookup user in permissions map
    Lambda-->>APIGW: JSON Response
    APIGW-->>Denodo: 200 OK

    Note over Denodo,Lambda: Response: userId, profiles, roles, datasources, maxRowsPerQuery, canExport
```

---

## 5. Test Users and Permissions

```mermaid
graph TD
    subgraph "Test Users (denodo-idp realm)"
        ANALYST["analyst@denodo.com\nPassword: Analyst@2026!\nProfile: data-analyst\nRole: viewer"]
        SCIENTIST["scientist@denodo.com\nPassword: Scientist@2026!\nProfile: data-scientist\nRole: editor"]
        ADMIN["admin@denodo.com\nPassword: Admin@2026!\nProfile: admin\nRole: admin"]
    end

    subgraph "Data Sources"
        RDS["RDS OpenData\n(entreprises, population_communes)"]
        GEO["geo.api.gouv.fr\n(communes, departements)"]
        SIRENE["api.insee.fr\n(SIRENE companies)"]
        ALL["All Data Sources"]
    end

    ANALYST -->|"read, query\nmaxRows: 10000"| RDS
    ANALYST -->|"read"| GEO
    SCIENTIST -->|"read, query, export\nmaxRows: 100000"| RDS
    SCIENTIST -->|"read"| GEO
    SCIENTIST -->|"read"| SIRENE
    ADMIN -->|"full access\nunlimited"| ALL

    style ANALYST fill:#3498db,color:#fff
    style SCIENTIST fill:#2ecc71,color:#fff
    style ADMIN fill:#e74c3c,color:#fff
```

| User | Password | Profile | Datasources | Max Rows | Export | Notes |
|------|----------|---------|-------------|----------|--------|-------|
| analyst@denodo.com | Analyst@2026! | data-analyst | rds-opendata, api-geo | 10,000 | No | Read-only access |
| scientist@denodo.com | Scientist@2026! | data-scientist | rds-opendata, api-geo | 100,000 | Yes | Advanced access, export enabled |
| admin@denodo.com | Admin@2026! | admin | all (*) | unlimited | Yes | Full administrative access |

> **Note:** While the scientist user's attributes may reference `api-sirene`, this datasource is **not actively configured** in the current deployment. The POC focuses on `rds-opendata` and `api-geo` (geo.api.gouv.fr) as the primary data sources.

---

## 6. Issues Resolved During Deployment

```mermaid
timeline
    title Deployment Issues Timeline (Feb 5-12, 2026)
    section Networking
        ECS tasks fail to start : ResourceInitializationError
                                : Fix: Public subnets + assignPublicIp
        CloudShell cannot reach RDS : Private subnet isolation
                                    : Fix: SSM send-command via Denodo EC2
    section Database
        DB name mismatch : database keycloak_provider not found
                         : Fix: Use default postgres DB
        Password mismatch : FATAL password authentication failed
                          : Fix: fix-opendata-password.sh syncs SM and RDS
        SQL file too large for SSM : Parameter size limit exceeded
                                   : Fix: S3 bucket intermediary transfer
    section Routing
        Health check 502 : ALB path /health/ready 404
                         : Fix: Changed to /auth/health/ready
        Admin token 404 : No rule for /auth/realms/master/*
                        : Fix: Added Priority 12 rule
        Keycloak UI blank : Static assets not routed
                          : Fix: Added /auth/* catch-all (Priority 99)
    section Security
        HTTPS required error : Keycloak enforces SSL on master
                             : Fix: kcadm.sh disables sslRequired
```

| # | Issue | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | ECS tasks fail to start | Private subnets, no NAT Gateway | Public subnets + assignPublicIp=ENABLED |
| 2 | CloudShell cannot reach private RDS | VPC isolation | SSM send-command routed through Denodo EC2 |
| 3 | DB name mismatch | Custom DB names not created | Use default `postgres` database |
| 4 | RDS password mismatch | Secrets Manager out of sync | `fix-opendata-password.sh` re-syncs |
| 5 | SQL file too large for SSM | SSM parameter size limit | S3 bucket as intermediary |
| 6 | Health check 502 | ALB health path wrong | Updated to `/auth/health/ready` |
| 7 | Admin token 404 | No ALB rule for master realm | Added `/auth/realms/master/*` (Priority 12) |
| 8 | Keycloak UI "Loading" | Static assets not forwarded | Added `/auth/*` catch-all (Priority 99) |
| 9 | HTTPS required error | Default SSL policy | `kcadm.sh` disables sslRequired at startup |

---

## 7. What Has Been Deployed (Complete)

```mermaid
flowchart LR
    subgraph "COMPLETED (As-Deployed Configuration)"
        A["1. VPC and\nNetworking\n(Existing VPC)"] --> B["2. Security\nGroups (6)"]
        B --> C["3. Secrets\nManager (6)"]
        C --> D["4. RDS\nDatabases (3)\nDefault postgres DB"]
        D --> E["5. OpenData\nSchema + Data\n15K companies"]
        E --> F["6. ECS Cluster\n+ Single Keycloak\n(Provider Active)"]
        F --> G["7. ALB +\nRouting Rules\nHTTP Only"]
        G --> H["8. Keycloak\n3 Realms + Users\n(Same Instance)"]
        H --> I["9. Lambda\nPermissions API"]
        I --> J["10. API Gateway\n+ API Key"]
        J --> K["11. Verification\nScript\n28 Tests Pass"]
    end

    style A fill:#27ae60,color:#fff
    style B fill:#27ae60,color:#fff
    style C fill:#27ae60,color:#fff
    style D fill:#27ae60,color:#fff
    style E fill:#27ae60,color:#fff
    style F fill:#27ae60,color:#fff
    style G fill:#27ae60,color:#fff
    style H fill:#27ae60,color:#fff
    style I fill:#27ae60,color:#fff
    style J fill:#27ae60,color:#fff
    style K fill:#27ae60,color:#fff
```

**All infrastructure and application components are deployed and operational.**

---

## 8. What's Next -- Denodo Integration

**All AWS infrastructure is deployed and verified.** The next phase is Denodo platform configuration.

See **[NEXT_STEPS.md](./NEXT_STEPS.md)** for detailed instructions.

```mermaid
flowchart LR
    subgraph "Phase 1: Denodo Configuration (Week 1)"
        D1["1.1 Configure OIDC\nAuthentication"]
        D2["1.2 Create RDS\nData Source"]
        D3["1.3 Create REST API\nData Source"]
        D4["1.4 Configure\nAuthorization API"]
        D5["1.5 Create\nDerived Views"]
    end

    subgraph "Phase 2: Testing (Week 1-2)"
        T1["2.1 Test User\nScenarios"]
        T2["2.2 Run Automated\nTest Suite"]
    end

    subgraph "Phase 3: Production Hardening (Week 2-3)"
        P1["3.1 Add HTTPS\n(ACM)"]
        P2["3.2 Add NAT\nGateway"]
        P3["3.3 Add WAF"]
        P4["3.4 Monitoring &\nAlerts"]
    end

    D1 --> D2 --> D3 --> D4 --> D5
    D5 --> T1 --> T2
    T2 --> P1 --> P2 --> P3 --> P4

    style D1 fill:#f39c12,color:#000
    style D2 fill:#f39c12,color:#000
    style D3 fill:#f39c12,color:#000
    style D4 fill:#f39c12,color:#000
    style D5 fill:#f39c12,color:#000
    style T1 fill:#e74c3c,color:#fff
    style T2 fill:#e74c3c,color:#fff
    style P1 fill:#95a5a6,color:#fff
    style P2 fill:#95a5a6,color:#fff
    style P3 fill:#95a5a6,color:#fff
    style P4 fill:#95a5a6,color:#fff
```

### Quick Start: Phase 1 (Denodo Configuration)

**Step 1: Configure OIDC Authentication**

In Denodo Admin Tool > Server Configuration > Authentication:

| Parameter | Value |
|-----------|-------|
| Issuer URL | `http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-consumer` |
| Client ID | `denodo-consumer` |
| Client Secret | Get from Secrets Manager: `denodo-poc/keycloak/client-secret` |
| Scopes | `openid email profile` |

**Step 2: Create RDS Data Source**

| Parameter | Value |
|-----------|-------|
| Type | PostgreSQL (JDBC) |
| Host | `denodo-poc-opendata-db.cacjdkje8yxa.eu-west-3.rds.amazonaws.com` |
| Port | `5432` |
| Database | `opendata` |
| Schema | `opendata` |
| User | `denodo` |
| Password | Get from Secrets Manager: `denodo-poc/opendata/db` |

Import tables: `entreprises`, `population_communes`, `entreprises_population`

**Step 3: Create REST API Data Source**

| Parameter | Value |
|-----------|-------|
| Type | JSON/REST |
| Base URL | `https://geo.api.gouv.fr` |
| Auth | None (public) |

Create base views for: `/communes`, `/departements`, `/regions`

**Step 4: Test End-to-End**

1. Login via OIDC (redirects to Keycloak)
2. Enter `analyst@denodo.com` / `Analyst@2026!`
3. Run query: `SELECT * FROM opendata.entreprises WHERE departement = '75' LIMIT 10`
4. Verify row limit enforcement (10,000 rows for analyst)

**Detailed instructions:** See [NEXT_STEPS.md](./NEXT_STEPS.md)

---

## 9. Optional Improvements (Post-POC)

```mermaid
flowchart LR
    subgraph "Production Hardening"
        HTTPS["Add HTTPS\n(ACM Certificate)"]
        NAT["Add NAT Gateway\n(Private ECS tasks)"]
        WAF["Add WAF\n(ALB protection)"]
    end

    subgraph "Monitoring"
        CW["CloudWatch\nDashboards"]
        ALARM["CloudWatch\nAlarms"]
        XRAY["X-Ray\nTracing"]
    end

    subgraph "Automation"
        IaC["Terraform / CDK\nInfrastructure as Code"]
        CICD["CI/CD Pipeline\nGitHub Actions"]
        CLEANUP["Validate\ncleanup-all.sh"]
    end

    style HTTPS fill:#e74c3c,color:#fff
    style NAT fill:#e67e22,color:#fff
    style WAF fill:#e67e22,color:#fff
    style CW fill:#f39c12,color:#000
    style ALARM fill:#f39c12,color:#000
    style XRAY fill:#f39c12,color:#000
    style IaC fill:#95a5a6,color:#fff
    style CICD fill:#95a5a6,color:#fff
    style CLEANUP fill:#95a5a6,color:#fff
```

| Priority | Task | Description |
|----------|------|-------------|
| High | HTTPS (ACM) | Eliminates `sslRequired=NONE` workaround |
| High | NAT Gateway | Move ECS to private subnets (security) |
| Medium | WAF | Protect ALB from malicious traffic |
| Medium | CloudWatch Dashboards | Centralized monitoring |
| Medium | Alarms | Alert on unhealthy targets, 5xx errors |
| Low | Terraform/CDK | Reproducible infrastructure |
| Low | CI/CD | Automated deployment pipeline |
| Low | Cleanup validation | Test `scripts/cleanup-all.sh` end-to-end |

---

## 10. Access URLs and Credentials

| Service | URL | Credentials |
|---------|-----|-------------|
| **Keycloak Admin** | http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/admin | admin / (Secrets Manager) |
| **Provider Realm** | http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-idp | -- |
| **Consumer Realm** | http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-consumer | -- |
| **OIDC Discovery** | http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-consumer/.well-known/openid-configuration | -- |
| **Health Check** | http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/health/ready | -- |
| **Permissions API** | https://9q5f8cjxe9.execute-api.eu-west-3.amazonaws.com/dev/api/v1/users/{email}/permissions | X-API-Key header |
| **Federation Test** | http://keycloak-alb-541762229.eu-west-3.elb.amazonaws.com/auth/realms/denodo-consumer/account | Test users above |

---

## 11. Scripts Reference

| Script | Purpose | When to Run |
|--------|---------|-------------|
| `scripts/complete-setup.sh` | Fix ALB, deploy API Gateway, verify all components | After initial deployment |
| `scripts/verify-all.sh` | Full automated test suite (6 test categories) | Before Denodo integration |
| `scripts/deploy-denodo-keycloak.sh` | Deploy base infrastructure (VPC, RDS, Secrets) | Initial deployment |
| `scripts/deploy-ecs-keycloak.sh` | Deploy ECS cluster, services, ALB | After infrastructure |
| `scripts/configure-keycloak.sh` | Create realms, users, OIDC federation | After ECS is healthy |
| `scripts/deploy-lambda-api.sh` | Deploy Lambda + API Gateway | After Keycloak config |
| `scripts/load-opendata.sh` | Load French OpenData into RDS | After RDS is available |
| `scripts/diagnose-rds.sh` | Debug RDS connectivity issues | Troubleshooting |
| `scripts/check-deployment-status.sh` | Quick status of all components | Anytime |
| `scripts/cleanup-all.sh` | Delete all AWS resources | When done with POC |
| `scripts/fix-lambda-api.sh` | Clean up duplicate APIs, redeploy Lambda | If API returns 500 |
| `tests/test-all.sh` | Run all test suites | Validation |

---

## 12. Retrieving Secrets via CloudShell

All credentials are stored in AWS Secrets Manager. Use these commands from CloudShell.

### Keycloak Admin Password

```bash
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/admin \
  --region eu-west-3 \
  --query SecretString --output text | jq -r '.password'
```

### OpenData RDS Credentials

```bash
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/opendata/db \
  --region eu-west-3 \
  --query SecretString --output text | jq '.'
```

Returns:

```json
{
  "username": "denodo",
  "password": "...",
  "host": "denodo-poc-opendata-db.cacjdkje8yxa.eu-west-3.rds.amazonaws.com",
  "port": 5432,
  "dbname": "opendata"
}
```

### Keycloak OIDC Client Secret

```bash
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/keycloak/client-secret \
  --region eu-west-3 \
  --query SecretString --output text | jq '.'
```

### Authorization API Key

```bash
aws secretsmanager get-secret-value \
  --secret-id denodo-poc/api/auth-key \
  --region eu-west-3 \
  --query SecretString --output text | jq -r '.apiKey'
```

### List All POC Secrets

```bash
aws secretsmanager list-secrets \
  --region eu-west-3 \
  --filters Key=name,Values=denodo-poc \
  --query 'SecretList[].Name' --output table
```

### One-Liner: Export All Credentials

```bash
export KC_ADMIN_PWD=$(aws secretsmanager get-secret-value --secret-id denodo-poc/keycloak/admin --region eu-west-3 --query SecretString --output text | jq -r '.password')
export DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id denodo-poc/opendata/db --region eu-west-3 --query SecretString --output text | jq -r '.password')
export CLIENT_SECRET=$(aws secretsmanager get-secret-value --secret-id denodo-poc/keycloak/client-secret --region eu-west-3 --query SecretString --output text | jq -r '.clientSecret')
export API_KEY=$(aws secretsmanager get-secret-value --secret-id denodo-poc/api/auth-key --region eu-west-3 --query SecretString --output text | jq -r '.apiKey')

echo "Keycloak admin:     $KC_ADMIN_PWD"
echo "OpenData DB:        $DB_PASSWORD"
echo "OIDC client secret: $CLIENT_SECRET"
echo "API key:            $API_KEY"
```

---

**Document Version:** 2.1
**Last Updated:** 12 February 2026
**Status:** Infrastructure 100% deployed -- awaiting Denodo platform integration
