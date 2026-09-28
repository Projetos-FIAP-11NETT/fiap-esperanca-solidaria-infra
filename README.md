# fiap-esperanca-solidaria-infra

Infraestrutura da plataforma **Esperança Solidária** (FIAP 11NETT): manifests Kubernetes, Terraform do
API Gateway/Lambdas no LocalStack e um `docker-compose` alternativo. **Este README é o guia mestre para
subir o ambiente inteiro do zero** — os READMEs dos outros repositórios explicam cada serviço
isoladamente e apontam pra cá quando o assunto é "rodar tudo junto".

---

## Sumário

- [Visão geral da arquitetura](#visão-geral-da-arquitetura)
- [Repositórios do projeto](#repositórios-do-projeto)
- [Estrutura deste repositório](#estrutura-deste-repositório)
- [Pré-requisitos](#pré-requisitos)
- [Subindo tudo do zero (Kubernetes)](#subindo-tudo-do-zero-kubernetes)
- [Portas e URLs](#portas-e-urls)
- [API Gateway: rotas e autorização](#api-gateway-rotas-e-autorização)
- [Secrets e configurações](#secrets-e-configurações)
- [Observabilidade](#observabilidade)
- [Ambiente alternativo: docker-compose](#ambiente-alternativo-docker-compose)
- [Rotina do dia a dia](#rotina-do-dia-a-dia)
- [Troubleshooting](#troubleshooting)
- [Pendências conhecidas](#pendências-conhecidas)

---

## Visão geral da arquitetura

```
                       ┌──────────────────────────────┐
  Navegador ──────────▶│  campanha-web (Vite :5173)   │
                       └──────────────┬───────────────┘
                                      │ HTTP (todas as chamadas via gateway)
                                      ▼
┌──────────────────────── LocalStack Pro (namespace localstack, NodePort 30466) ────────────────────────┐
│  API Gateway REST "local-api-gateway-v1" (stage dev)                                                 │
│     │  rotas CUSTOM ──▶ Lambda "fiap-api-authorizer" (lambda-authorizer: valida JWT Firebase + papel) │
│     │  HTTP_PROXY ──▶ campaigns-api.apps.svc.cluster.local:80 / users-api.apps.svc.cluster.local:80  │
│  SQS: process-donation-payment, notification-queue      S3: campanha-images, usuario-images          │
│  Lambda "email-function" (notificacao-lambda) ◀── trigger SQS notification-queue ──▶ SES             │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
          │                                   │
          ▼                                   ▼
┌─ namespace apps ──────────────────────────────────────────────┐   ┌─ namespace database ─────────────┐
│ campaigns-api (campanha-api)  ── publica ──▶ SQS doações      │   │ postgresdb-campanha (Postgres 16)│
│ users-api     (usuario-api)   ── (e-mail) ─▶ SQS notificações*│──▶│   campanha-db (schema fundraising)│
│ donation-worker (doacao-work) ◀── consome ── SQS doações      │   │   users-db                       │
└───────────────────────────────────────────────────────────────┘   │ redis (sessões / cache)          │
                                                                    │ pgadmin, redisinsight            │
┌─ namespace monitoring ────────────────────────────────────────┐   └──────────────────────────────────┘
│ grafana, prometheus, loki + promtail, tempo, zabbix           │
└───────────────────────────────────────────────────────────────┘
```

\* A publicação de e-mail pelo `usuario-api` existe mas está desligada no código (ver pendências).

**Fluxo de uma doação (ponta a ponta):**

1. Doador faz login no front → `POST /users/api/v1/User/Login` (gateway → users-api → Firebase) e recebe
   `idToken` + `refreshToken` + `sessionId`.
2. Front chama `POST /api/v1/doacoes` com `Authorization: Bearer <idToken>`; o gateway invoca a Lambda
   authorizer, que valida o token e o papel `Doador`.
3. `campanha-api` grava a doação como `Pending` e publica `{DonationId, CorrelationId}` na fila
   `process-donation-payment`.
4. `doacao-work` consome a mensagem, simula o pagamento, marca `Approved`/`Rejected` e, se aprovada,
   soma o valor em `Campaigns.TotalRaised`.
5. O front mostra a doação em "Minhas doações" (`GET /api/v1/doacoes/me`).

---

## Repositórios do projeto

| Repositório | O que é | Imagem / artefato |
|---|---|---|
| `fiap-esperanca-solidaria-infra` | Este repo: k8s, Terraform, compose | — |
| `fiap-esperanca-solidaria-campanha-api` | API .NET 10 de campanhas e doações | `projetofiap/fiap-esperanca-solidaria-campanha-api` |
| `fiap-esperanca-solidaria-usuario-api` | API .NET 10 de usuários, login e sessão (Firebase) | `projetofiap/fiap-esperanca-solidaria-usuario-api` |
| `fiap-esperanca-solidaria-doacao-work` | Worker .NET que processa pagamentos das doações | `projetofiap/fiap-esperanca-solidaria-doacao-work` |
| `fiap-esperanca-solidaria-lambda-authorizer` | Lambda authorizer do API Gateway | `terraform/lambda-auth/function.zip` |
| `fiap-esperanca-solidaria-notificacao-lambda` | Lambda de envio de e-mail (SQS → SES) | `terraform/lambda-notification/function.zip` |
| `fiap-esperanca-solidaria-campanha-web` | Front React (Vite) | roda local com `npm run dev` |

---

## Estrutura deste repositório

```
.
├── k8s/
│   ├── namespaces/                 # apps, database, localstack, monitoring
│   ├── register-secrets-configs.ps1# cria shared-config/shared-secret (apps) e localstack-secret
│   ├── secrets-configs/
│   │   └── configmap.yaml          # versão declarativa do shared-config (referência)
│   ├── shared/
│   │   ├── storage-class.yaml      # StorageClass "hostpath" (Docker Desktop)
│   │   ├── postgres-campanha/      # StatefulSet Postgres 16 + PV/PVC + Service ClusterIP
│   │   ├── redis/                  # Redis 7 (senha via secret)
│   │   ├── pgadmin/                # pgAdmin (NodePort 30090)
│   │   └── redisinsight/           # RedisInsight (NodePort 30540)
│   ├── localstack/                 # LocalStack Pro: deployment, svc (30466), pvc, rbac, configmap
│   ├── campaigns-api/              # Deployment + Service (NodePort 30081) do campanha-api
│   ├── users-api/                  # Deployment + Service (NodePort 30084) do usuario-api
│   ├── donation-worker/            # Deployment + Service (NodePort 30083) do doacao-work
│   └── observability/              # grafana, loki, promtail, tempo, prometheus, zabbix + PVs
├── terraform/
│   ├── k8s/                        # ★ usado com o cluster k8s: API Gateway, authorizer, SQS, Lambda de e-mail, SES
│   ├── docker-compose/             # mesma coisa, mas apontando para os containers do docker-compose
│   ├── lambda-auth/function.zip    # pacote da Lambda authorizer (gerado pelo build-and-deploy.ps1 do repo dela)
│   └── lambda-notification/function.zip # pacote da Lambda de e-mail
├── docker-compose.yaml             # ambiente alternativo sem k8s
├── env.example                     # variáveis do docker-compose
└── servers.json                    # servidores pré-cadastrados no pgAdmin do compose
```

### Arquivos que merecem atenção

- **`terraform/k8s/main.tf`** — o coração do gateway. Cria a Lambda authorizer (`fiap-api-authorizer`), a
  REST API via `terraform_data.api_gateway_custom` (um `local-exec` com AWS CLI, porque o provider não
  lida bem com o LocalStack nesse caso — inclui `--binary-media-types 'multipart/form-data'` pra upload de
  imagens), todos os resources/methods/integrations `HTTP_PROXY`, a permissão da Lambda, as filas SQS
  `notification-queue` e `process-donation-payment`, a Lambda `email-function` com trigger SQS e a
  identidade SES.
- **`terraform/k8s/variables.tf`** — nomes (`api_name = local-api-gateway-v1`, `stage_name = dev`,
  `lambda_name = fiap-api-authorizer`), porta dos Services (`container_port = 80`), env da Lambda de e-mail
  e `firebase_project_id`/`jwks_metadata_address` do authorizer.
- **`terraform/k8s/terraform.tfvars.example`** — copie para `terraform.tfvars` se quiser sobrescrever algo.
- **`k8s/register-secrets-configs.ps1`** — cria/atualiza (idempotente, `--dry-run=client | kubectl apply`)
  os secrets e configmaps usados pelas aplicações. Lê `$env:LOCALSTACK_AUTH_TOKEN`, `$env:FIREBASE_APIKEY`
  e o arquivo `k8s/secrets-configs/firebase-service-account.json`.
- **`k8s/localstack/localstack-deployment.yaml`** — LocalStack **Pro** (o API Gateway exige licença Pro).
  Sem token válido o pod entra em crash loop.

---

## Pré-requisitos

| Ferramenta | Para quê |
|---|---|
| Docker Desktop com **Kubernetes habilitado** | cluster local (contexto `docker-desktop`) |
| `kubectl` | aplicar manifests |
| Terraform >= 1.5 | API Gateway, Lambdas, SQS no LocalStack |
| AWS CLI v2 | usado pelo `local-exec` do Terraform e para depurar o LocalStack |
| PowerShell 5.1+ | scripts `.ps1` (secrets e build das Lambdas) |
| .NET SDK 10 | build da Lambda authorizer e das APIs (se for rodar local) |
| .NET SDK 8 | build da Lambda de notificação |
| Node.js 20+ | front `campanha-web` |
| Token do **LocalStack Pro** | `LOCALSTACK_AUTH_TOKEN` |
| Projeto Firebase | API key (`FIREBASE_APIKEY`) + service account JSON |

> **Nunca commite** o token do LocalStack, a API key do Firebase, o JSON da service account ou senhas
> reais. O `.gitignore` já ignora `*.ps1` novos e `*configmap.yaml`, mas confira sempre o `git status`.

---

## Subindo tudo do zero (Kubernetes)

Todos os comandos abaixo são executados a partir da raiz deste repositório, em PowerShell.

### 1. Cluster e namespaces

```powershell
kubectl config use-context docker-desktop
kubectl apply -f k8s/namespaces/
kubectl apply -f k8s/shared/storage-class.yaml
kubectl apply -f k8s/observability/monitoring-pv.yaml   # PVs usados pelo monitoring (opcional)
```

### 2. Secrets e configs

Coloque o JSON da service account do Firebase em `k8s/secrets-configs/firebase-service-account.json`
(arquivo **não versionado**) e rode:

```powershell
$env:LOCALSTACK_AUTH_TOKEN = "ls-..."     # seu token LocalStack Pro
$env:FIREBASE_APIKEY       = "AIza..."    # Web API key do projeto Firebase
.\k8s\register-secrets-configs.ps1
```

O script cria `shared-config` e `shared-secret` no namespace `apps` e `localstack-secret` no namespace
`localstack`. **Ele não cria** os secrets do namespace `database` nem o `CORS_ALLOWED_ORIGINS`; crie-os
manualmente (valores de desenvolvimento, iguais aos das connection strings do script):

```powershell
# Postgres/Redis (namespace database)
kubectl create secret generic shared-secret -n database `
  --from-literal=POSTGRES_USER=postgresAdmin `
  --from-literal=POSTGRES_PASSWORD=postgresAdmin `
  --from-literal=REDIS_PASSWORD=redisPassword `
  --dry-run=client -o yaml | kubectl apply -f -

# pgAdmin (namespace database) — escolha o e-mail/senha de login do pgAdmin
kubectl create secret generic pgadmin-secret -n database `
  --from-literal=PGADMIN_DEFAULT_EMAIL=admin@admin.com `
  --from-literal=PGADMIN_DEFAULT_PASSWORD=<senha> `
  --dry-run=client -o yaml | kubectl apply -f -

# Origem do front liberada no CORS do campaigns-api (referenciada pelo campaigns-deployment.yaml)
kubectl patch configmap shared-config -n apps --type merge `
  -p '{\"data\":{\"CORS_ALLOWED_ORIGINS\":\"http://localhost:5173\"}}'
```

> O Zabbix (opcional) ainda espera um secret `postgres-secret` no namespace `monitoring` com
> `POSTGRES_USER`, `POSTGRES_PASSWORD` e `POSTGRES_DB`.

### 3. Bancos, cache e LocalStack

```powershell
kubectl apply -R -f k8s/shared/
kubectl apply -f k8s/localstack/

kubectl get pods -n database -w      # espere postgres/redis Running
kubectl get pods -n localstack -w    # espere localstack Running (1/1)
curl http://localhost:30466/_localstack/health
```

Os bancos `campanha-db` e `users-db` são criados pelas migrations das próprias APIs no primeiro start
(`campanha-api` também cria o schema `fundraising`, que o `doacao-work` usa — por isso o worker depende
de a `campanha-api` ter subido pelo menos uma vez).

### 4. Aplicações

```powershell
kubectl apply -f k8s/campaigns-api/ -f k8s/users-api/ -f k8s/donation-worker/
kubectl get pods -n apps -w
```

As imagens usadas são as `:latest` do Docker Hub (`projetofiap/...`, `imagePullPolicy: Always`),
publicadas pelo pipeline de CD de cada repositório ao criar uma tag `v*`. Para forçar o pull de uma
nova `latest`:

```powershell
kubectl rollout restart deployment -n apps
```

### 5. Observabilidade (opcional)

```powershell
kubectl apply -R -f k8s/observability/
```

### 6. Lambdas e API Gateway (Terraform)

Garanta que os pacotes estão atualizados:

- `terraform/lambda-auth/function.zip` — gerado por `build-and-deploy.ps1` no repo
  `fiap-esperanca-solidaria-lambda-authorizer` (ele copia o zip pra cá).
- `terraform/lambda-notification/function.zip` — gerado no repo `fiap-esperanca-solidaria-notificacao-lambda`.

A Lambda authorizer roda dentro do LocalStack e precisa enxergar o endpoint do LocalStack em
`localhost:4566`; abra um port-forward **e deixe-o aberto** num terminal separado:

```powershell
kubectl port-forward -n localstack svc/localstack 4566:4566
```

Em outro terminal:

```powershell
cd terraform/k8s
terraform init
terraform apply -replace="terraform_data.api_gateway_custom"
```

O `-replace` força recriar a REST API — necessário sempre que o LocalStack reinicia, porque **ele não
persiste estado**: fila, Lambda e gateway somem a cada restart do pod. O id da REST API muda toda vez.

Para descobrir o id atual:

```powershell
aws apigateway get-rest-apis --endpoint-url http://localhost:30466 --region us-east-1 `
  --query "items[?name=='local-api-gateway-v1'].id" --output text
```

### 7. Front

No repo `fiap-esperanca-solidaria-campanha-web`:

```powershell
npm install
npm run dev     # o predev roda gateway:sync e grava o id atual do gateway no .env.development
```

Acesse http://localhost:5173.

### 8. Conferência rápida

```powershell
$id  = aws apigateway get-rest-apis --endpoint-url http://localhost:30466 --region us-east-1 `
         --query "items[?name=='local-api-gateway-v1'].id" --output text
$gw  = "http://localhost:30466/restapis/$id/dev/_user_request_"
curl "$gw/health"
curl "$gw/api/v1/campanhas"
```

---

## Portas e URLs

| Serviço | Namespace | Acesso pelo host | Dentro do cluster |
|---|---|---|---|
| LocalStack (gateway, SQS, S3, Lambda) | localstack | http://localhost:30466 | `localstack.localstack.svc.cluster.local:4566` |
| API Gateway (base) | — | `http://localhost:30466/restapis/<id>/dev/_user_request_` | — |
| campaigns-api | apps | http://localhost:30081 (docs em `/docs`) | `campaigns-api.apps.svc.cluster.local:80` |
| users-api | apps | http://localhost:30084 (Scalar na raiz) | `users-api.apps.svc.cluster.local:80` |
| donation-worker | apps | http://localhost:30083 (`/health/live`, `/metrics`) | `donation-worker.apps.svc.cluster.local:80` |
| Postgres | database | — (ClusterIP; use pgAdmin ou port-forward) | `postgresdb-campanha.database.svc.cluster.local:5432` |
| Redis | database | — (ClusterIP) | `redis.database.svc.cluster.local:6379` |
| pgAdmin | database | http://localhost:30090 | — |
| RedisInsight | database | http://localhost:30540 | — |
| Grafana | monitoring | http://localhost:30300 | — |
| Zabbix web | monitoring | http://localhost:30080 | — |

Os Services das APIs expõem a porta 80 e encaminham para 8080 no container.

---

## API Gateway: rotas e autorização

Base: `http://localhost:30466/restapis/<id>/dev/_user_request_`

| Método | Rota | Auth | Destino |
|---|---|---|---|
| GET | `/health` | NONE | campaigns-api |
| GET | `/api/v1/campanhas` | NONE | `GET /api/v1/Campaign/public` |
| POST | `/api/v1/campanhas` | CUSTOM (GestorONG) | `POST /api/v1/Campaign` |
| GET | `/api/v1/campanhas/gestao` | CUSTOM (GestorONG) | `GET /api/v1/Campaign` |
| GET | `/api/v1/campanhas/{id}` | NONE | `GET /api/v1/Campaign/{id}` |
| PUT | `/api/v1/campanhas/{id}` | CUSTOM (GestorONG) | `PUT /api/v1/Campaign/{id}` |
| POST | `/api/v1/campanhas/images` | CUSTOM (GestorONG) | `POST /api/v1/Campaign/images` |
| POST | `/api/v1/campanhas/{id}/cancel` | CUSTOM (GestorONG) | `POST /api/v1/Campaign/{id}/cancel` |
| POST | `/api/v1/doacoes` | CUSTOM (Doador) | `POST /api/v1/Donation` |
| GET | `/api/v1/doacoes/me` | CUSTOM (Doador) | `GET /api/v1/Donation/me` |
| GET | `/api/v1/doacoes/{id}` | CUSTOM (Doador/GestorONG) | `GET /api/v1/Donation/{id}` |
| POST | `/users/api/v1/User/Doador` | NONE | users-api (cadastro de doador) |
| POST | `/users/api/v1/User/images` | NONE | users-api (foto de perfil) |
| POST | `/users/api/v1/User/Login` | NONE | users-api |
| POST | `/users/api/v1/User/RefreshToken` | NONE | users-api |
| GET / DELETE | `/users/api/v1/User/Session/{sessionId}` | CUSTOM | users-api |
| PUT | `/users/api/v1/User/MakeGestorONG` | CUSTOM (GestorONG) | users-api |

- Rotas `NONE` não invocam a Lambda. Rotas `CUSTOM` invocam `fiap-api-authorizer`, que valida o JWT do
  Firebase e confere o papel (claim `roles`) contra a tabela de regras em
  `lambda-authorizer/Infrastructure/AuthorizationRulesService.cs` (repo do authorizer).
- As integrações são `HTTP_PROXY` para os FQDNs dos Services no namespace `apps`.
- Adicionou rota nova? Ela precisa existir **nos dois lugares**: `terraform/k8s/main.tf` (e
  `terraform/docker-compose/main.tf`) e nas regras do authorizer, senão o authorizer nega por padrão.

---

## Secrets e configs

Resumo do que cada aplicação recebe (ver os `*-deployment.yaml`):

| Chave | Origem | Usado por |
|---|---|---|
| `SQS_SERVICE_URL` | shared-config | campaigns (SQS e S3), users (SQS e S3), worker |
| `SQS_DONATION_QUEUE_URL` | shared-config | campaigns (`SqsSettings__EmailQueueURL`\*), worker (`Sqs__QueueUrl`) |
| `SQS_EMAIL_QUEUE_URL` | shared-config | users (`SqsSettings__EmailQueueURL`) |
| `CORS_ALLOWED_ORIGINS` | shared-config (**criar manualmente**) | campaigns |
| `SQS_REGION` / `SQS_ACCESS_KEY` / `SQS_SECRET_KEY` | shared-secret | todos (credenciais fake `test`) |
| `DB_CAMPAIGN_CONNECTION_STRING` | shared-secret | campaigns |
| `DB_USER_CONNECTION_STRING` | shared-secret | users |
| `DB_DOACAO_CONNECTION_STRING` | shared-secret | worker (`Search Path=fundraising`) |
| `REDIS_CONNECTION_STRING` | shared-secret | campaigns, users |
| `FIREBASE_APIKEY` / `FIREBASE_PROJECT_ID` / `FIREBASE_CREDENTIALJSON` | shared-secret | users |
| `LOCALSTACK_AUTH_TOKEN` | localstack-secret | localstack |

\* O nome da propriedade no `campanha-api` é `EmailQueueUrl` por herança, mas o valor é a fila de
doações `process-donation-payment`.

---

## Observabilidade

- **Tempo** (`tempo.monitoring.svc.cluster.local:4318`) recebe traces OTLP das APIs
  (`OpenTelemetry__TempoEndpoint`).
- **Prometheus** faz scrape dos pods anotados com `prometheus.io/scrape: "true"` (`/metrics`, porta 8080).
- **Loki + Promtail** coletam os logs dos containers.
- **Grafana** (http://localhost:30300) consolida os três.
- **Zabbix** (server, web, agent DaemonSet, Postgres próprio) monitora os nós.

---

## Ambiente alternativo: docker-compose

`docker-compose.yaml` sobe LocalStack Pro (4566), Redis (6379), RedisInsight (5540), Postgres (porta do
host **5444**), pgAdmin (**5050**) e as três aplicações a partir das imagens do Docker Hub (campaigns-api
em 30081, users-api em 30084, worker sem porta exposta), numa rede externa
`fiap-esperanca-solidaria-network`. Todas as portas/credenciais vêm do `.env` (modelo em `env.example`).

```powershell
Copy-Item env.example .env          # troque LOCALSTACK_TOKEN=REPLACE... pelo seu token e revise o resto
docker network create fiap-esperanca-solidaria-network
docker compose up -d
cd terraform/docker-compose
terraform init
terraform apply
```

> O compose monta `./localstack-init`, que não existe no repositório — crie a pasta vazia (ou remova o
> volume) antes do `up`. O caminho principal e testado do projeto é o Kubernetes.

---

## Rotina do dia a dia

Depois que tudo já foi criado uma vez, o que costuma ser preciso após reiniciar a máquina/Docker:

```powershell
kubectl get pods -A                                        # tudo Running?
kubectl port-forward -n localstack svc/localstack 4566:4566  # terminal separado, deixar aberto
cd terraform/k8s; terraform apply -replace="terraform_data.api_gateway_custom"
# no campanha-web:
npm run dev                                                # sincroniza o id novo do gateway
```

Para atualizar as imagens depois de um release (`v*`) em algum repo:

```powershell
kubectl rollout restart deployment/campaigns-deployment -n apps   # ou users-deployment / donation-deployment
```

---

## Troubleshooting

| Sintoma | Causa provável / solução |
|---|---|
| Pod do LocalStack em `CrashLoopBackOff` | Token Pro ausente/inválido em `localstack-secret`. Reexporte `$env:LOCALSTACK_AUTH_TOKEN` e rode o script de secrets; depois `kubectl rollout restart deployment -n localstack`. |
| Gateway responde `404`/`NoSuchBucket` | REST API não existe (LocalStack reiniciou). Rode o `terraform apply -replace=...`. No front, `npm run gateway:sync`. |
| Rotas `CUSTOM` retornam `500`/timeout | Port-forward `4566` não está aberto, ou o `function.zip` do authorizer está desatualizado. |
| Rotas `CUSTOM` retornam `403` | Token sem o papel exigido (claim `roles`) ou rota ausente da tabela de regras do authorizer. |
| Pod `CreateContainerConfigError` | Falta alguma chave de configmap/secret (ex.: `CORS_ALLOWED_ORIGINS`). `kubectl describe pod <pod> -n apps`. |
| Erro de CORS no front | O front só fala com o gateway; confira se a URL do gateway está atualizada (`npm run gateway:sync`). O `Cors__AllowedOrigins__0` das APIs só importa para quem as chama direto (Scalar, testes locais). |
| Doação fica `Pending` | Worker parado, fila inexistente (terraform não aplicado) ou forma de pagamento sem taxa configurada no worker (Boleto). |
| Login falha com erro do Firebase | `FIREBASE_APIKEY`/`FIREBASE_CREDENTIALJSON` incorretos no `shared-secret`. |

---

## Pendências conhecidas

- `k8s/users-api/users-deployment.yaml` não define `Cors__AllowedOrigins__0` (hoje configurado manualmente
  com `kubectl set env`); o `campaigns-deployment.yaml` referencia `CORS_ALLOWED_ORIGINS`, que o
  `register-secrets-configs.ps1` não cria.
- O script de secrets não cria `shared-secret`/`pgadmin-secret` no namespace `database` nem o
  `postgres-secret` do Zabbix.
- `docker-compose.yaml` referencia `./localstack-init`, ausente no repo.
- O `usuario-api` tem a publicação do e-mail de boas-vindas comentada no `CreateUserCommandHandler`, então
  a `notification-queue`/`email-function` não recebe mensagens no fluxo normal.
- `ses_verified_email` ainda usa o domínio herdado `no-reply@fiapcloudgames.local`.
