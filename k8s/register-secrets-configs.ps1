# Cria/atualiza os ConfigMaps e Secrets usados pelos manifests deste diretorio.
#
# Valores sensiveis NAO ficam no repositorio, entram por variavel de ambiente:
#   $env:LOCALSTACK_AUTH_TOKEN  token da licenca LocalStack Pro (necessario pra API Gateway)
#   $env:FIREBASE_APIKEY        API key do projeto Firebase (mesma de Firebase:ApiKey do usuario-api)
# E o arquivo secrets-configs\firebase-service-account.json (ignorado pelo git) precisa existir.
#
# Uso:
#   $env:LOCALSTACK_AUTH_TOKEN = "ls-..."; $env:FIREBASE_APIKEY = "AIza..."
#   .\k8s\register-secrets-configs.ps1
#
# Namespaces (ver k8s/namespaces/*.yaml): apps, database, localstack, monitoring.
# shared-config/shared-secret vao para "apps" (onde rodam campaigns-api/users-api/donation-worker).
# localstack-secret vai para "localstack" (onde roda o pod do LocalStack).
# Postgres/Redis estao em "database"; por isso as connection strings abaixo
# usam o FQDN "<service>.database.svc.cluster.local" em vez do nome curto do Service.

$ErrorActionPreference = "Stop"

$firebaseJson = Join-Path $PSScriptRoot "secrets-configs\firebase-service-account.json"
$missing = @()
if (-not $env:LOCALSTACK_AUTH_TOKEN) { $missing += "`$env:LOCALSTACK_AUTH_TOKEN" }
if (-not $env:FIREBASE_APIKEY) { $missing += "`$env:FIREBASE_APIKEY" }
if (-not (Test-Path $firebaseJson)) { $missing += $firebaseJson }
if ($missing.Count -gt 0) {
    throw "Faltando: $($missing -join ', ')"
}

Write-Host "Aplicando recursos..." -ForegroundColor Cyan

# ConfigMap compartilhado: SQS/S3 apontam pro LocalStack rodando no namespace "localstack".
# As filas sao as mesmas criadas pelo terraform/k8s (sqs_queue_name e sqs_donation_queue_name
# em variables.tf).
$sharedConfigArgs = @(
    "create", "configmap", "shared-config", "-n", "apps",
    "--from-literal=SQS_SERVICE_URL=http://localstack.localstack.svc.cluster.local:4566",
    "--from-literal=SQS_EMAIL_QUEUE_URL=http://localstack.localstack.svc.cluster.local:4566/000000000000/notification-queue",
    "--from-literal=SQS_DONATION_QUEUE_URL=http://localstack.localstack.svc.cluster.local:4566/000000000000/process-donation-payment",
    "--dry-run=client", "-o", "yaml"
)
kubectl @sharedConfigArgs | kubectl apply -f -

# Secret compartilhado: credenciais fake do SQS/S3/localstack, banco (postgresdb-campanha no
# namespace "database", que hospeda campanha-db, users-db e o schema "fundraising" usado pelo
# donation-worker) e redis. Senhas de banco/redis sao apenas de desenvolvimento local.
# FIREBASE_CREDENTIALJSON: o users-api espera o conteudo JSON inline (Firebase__CredentialJson),
# nao um caminho de arquivo - --from-file cria uma chave cujo VALOR e o conteudo do arquivo.
$sharedSecretArgs = @(
    "create", "secret", "generic", "shared-secret", "-n", "apps",
    "--type=Opaque",
    "--from-literal=SQS_REGION=us-east-1",
    "--from-literal=SQS_ACCESS_KEY=test",
    "--from-literal=SQS_SECRET_KEY=test",
    "--from-literal=AWS_ACCESS_KEY_ID=test",
    "--from-literal=AWS_SECRET_ACCESS_KEY=test",
    "--from-literal=AWS_SESSION_TOKEN=test",
    "--from-literal=POSTGRES_USER=postgresAdmin",
    "--from-literal=POSTGRES_PASSWORD=postgresAdmin",
    "--from-literal=REDIS_PASSWORD=redisPassword",
    "--from-literal=REDIS_CONNECTION_STRING=redis.database.svc.cluster.local:6379,password=redisPassword,abortConnect=false",
    "--from-literal=DB_CAMPAIGN_CONNECTION_STRING=Host=postgresdb-campanha.database.svc.cluster.local;Port=5432;Database=campanha-db;Username=postgresAdmin;Password=postgresAdmin;",
    "--from-literal=DB_USER_CONNECTION_STRING=Host=postgresdb-campanha.database.svc.cluster.local;Port=5432;Database=users-db;Username=postgresAdmin;Password=postgresAdmin;",
    "--from-literal=DB_DOACAO_CONNECTION_STRING=Host=postgresdb-campanha.database.svc.cluster.local;Port=5432;Database=campanha-db;Username=postgresAdmin;Password=postgresAdmin;Search Path=fundraising;",
    "--from-literal=FIREBASE_APIKEY=$($env:FIREBASE_APIKEY)",
    "--from-literal=FIREBASE_PROJECT_ID=esperancasolidaria",
    "--from-file=FIREBASE_CREDENTIALJSON=$firebaseJson",
    "--dry-run=client", "-o", "yaml"
)
kubectl @sharedSecretArgs | kubectl apply -f -

# Segredos exigidos pelo proprio pod do localstack (LOCALSTACK_AUTH_TOKEN e obrigatorio
# no deployment; as credenciais AWS sao fake). Vive no namespace "localstack".
$localstackSecretArgs = @(
    "create", "secret", "generic", "localstack-secret", "-n", "localstack",
    "--from-literal=LOCALSTACK_AUTH_TOKEN=$($env:LOCALSTACK_AUTH_TOKEN)",
    "--from-literal=AWS_ACCESS_KEY_ID=test",
    "--from-literal=AWS_SECRET_ACCESS_KEY=test",
    "--from-literal=AWS_SESSION_TOKEN=test",
    "--dry-run=client", "-o", "yaml"
)
kubectl @localstackSecretArgs | kubectl apply -f -

Write-Host "Recursos aplicados com sucesso." -ForegroundColor Green
