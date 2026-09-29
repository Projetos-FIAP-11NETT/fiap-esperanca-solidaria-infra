# Cria/atualiza namespaces, ConfigMaps e Secrets usados pelos manifests deste diretorio.
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
# Os demais valores (senhas do Postgres/Redis/pgAdmin/Zabbix, credenciais "test" do
# LocalStack) sao defaults de desenvolvimento local.

param(
    [string]$Namespace = "database"
)

$AppNamespace = "apps"
$DatabaseNamespace = "database"
$LocalstackNamespace = "localstack"
$MonitoringNamespace = "monitoring"

$ErrorActionPreference = "Stop"

$firebaseJson = Join-Path $PSScriptRoot "secrets-configs\firebase-service-account.json"
$missing = @()
if (-not $env:LOCALSTACK_AUTH_TOKEN) { $missing += "`$env:LOCALSTACK_AUTH_TOKEN" }
if (-not $env:FIREBASE_APIKEY) { $missing += "`$env:FIREBASE_APIKEY" }
if (-not (Test-Path $firebaseJson)) { $missing += $firebaseJson }
if ($missing.Count -gt 0) {
    throw "Faltando: $($missing -join ', ')"
}

kubectl create namespace $AppNamespace --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $DatabaseNamespace --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $LocalstackNamespace --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $MonitoringNamespace --dry-run=client -o yaml | kubectl apply -f -

Write-Host "Aplicando recursos no namespace '$AppNamespace' e '$DatabaseNamespace'..." -ForegroundColor Cyan

# ConfigMap compartilhado para os apps
$localstackHost = "http://localstack.$LocalstackNamespace.svc.cluster.local:4566/"
$sharedConfigArgs = @(
    "create", "configmap", "shared-config", "-n", $AppNamespace,
    "--from-literal=MONGODB_ADDRESS=mongodb",
    "--from-literal=MONGODB_PORT=27017",
    "--from-literal=REDIS_ADDRESS=redis",
    "--from-literal=REDIS_PORT=6379",
    "--from-literal=LOCALSTACK_ENDPOINT=$localstackHost",
    "--from-literal=SQS_SERVICE_URL=http://localstack.$LocalstackNamespace.svc.cluster.local:4566",
    "--from-literal=SQS_EMAIL_QUEUE_URL=http://localstack.$LocalstackNamespace.svc.cluster.local:4566/000000000000/notification-queue",
    "--from-literal=SQS_DONATION_QUEUE_URL=http://localstack.$LocalstackNamespace.svc.cluster.local:4566/000000000000/process-donation-payment",
    "--from-literal=ELASTICSEARCH_URI=http://elasticsearch.$AppNamespace.svc.cluster.local:9200",
    "--from-literal=ELASTICSEARCH_INDEX=games",
    "--from-literal=CORS_ALLOWED_ORIGINS=http://localhost:5173"
    "--dry-run=client", "-o", "yaml"
)
kubectl @sharedConfigArgs | kubectl apply -f -

# Secret compartilhado para os apps
$redisHost = "redis.$DatabaseNamespace.svc.cluster.local:6379"
$postgresHost = "postgresdb-campanha.$DatabaseNamespace.svc.cluster.local"

$appSharedSecretArgs = @(
    "create", "secret", "generic", "shared-secret", "-n", $AppNamespace,
    "--type=Opaque",
    "--from-literal=AWS_ACCESS_KEY_ID=test",
    "--from-literal=AWS_SECRET_ACCESS_KEY=test",
    "--from-literal=AWS_SESSION_TOKEN=",
    "--from-literal=LOCALSTACK_AUTH_TOKEN=$($env:LOCALSTACK_AUTH_TOKEN)",

    "--from-literal=MONGO_ROOT_USER=mongoAdmin",
    "--from-literal=MONGO_ROOT_PASSWORD=mongoPassword",
    "--from-literal=MONGO_EXPRESS_USER=admin",
    "--from-literal=MONGO_EXPRESS_PASSWORD=password",
    "--from-literal=MONGO_CONNECTION_STRING=mongodb://mongoAdmin:mongoPassword@mongodb:27017/",
    "--from-literal=MONGO_EXPRESS_URL=mongodb://mongoAdmin:mongoPassword@mongodb:27017/",

    "--from-literal=REDIS_PASSWORD=redisPassword",
    "--from-literal=REDIS_CONNECTION_STRING=$redisHost,password=redisPassword,abortConnect=false",

    "--from-literal=DB_CAMPAIGN_CONNECTION_STRING=Host=$postgresHost;Port=5432;Database=campanha-db;Username=postgresAdmin;Password=postgresAdmin",
    "--from-literal=DB_USER_CONNECTION_STRING=Host=$postgresHost;Port=5432;Database=campanha-db;Username=postgresAdmin;Password=postgresAdmin",
    "--from-literal=DB_DOACAO_CONNECTION_STRING=Host=$postgresHost;Port=5432;Database=campanha-db;Username=postgresAdmin;Password=postgresAdmin;Search Path=fundraising",

    "--from-literal=POSTGRES_USER=postgresAdmin",
    "--from-literal=POSTGRES_PASSWORD=postgresAdmin",

    "--from-literal=SQS_REGION=us-east-1",
    "--from-literal=SQS_ACCESS_KEY=test",
    "--from-literal=SQS_SECRET_KEY=test",

    "--from-literal=FIREBASE_APIKEY=$($env:FIREBASE_APIKEY)",
    "--from-literal=FIREBASE_PROJECT_ID=esperancasolidaria",
    "--from-file=FIREBASE_CREDENTIALJSON=$PSScriptRoot\secrets-configs\firebase-service-account.json",
    "--dry-run=client", "-o", "yaml"
)

$databaseSharedSecretArgs = @(
    "create", "secret", "generic", "shared-secret", "-n", $DatabaseNamespace,
    "--type=Opaque",
    "--from-literal=REDIS_PASSWORD=redisPassword",
    "--from-literal=POSTGRES_USER=postgresAdmin",
    "--from-literal=POSTGRES_PASSWORD=postgresAdmin",
    "--dry-run=client", "-o", "yaml"
)

kubectl delete secret shared-secret -n $AppNamespace --ignore-not-found
kubectl delete secret shared-secret -n $DatabaseNamespace --ignore-not-found
kubectl @appSharedSecretArgs | kubectl apply -f -
kubectl @databaseSharedSecretArgs | kubectl apply -f -

# Secret do pgAdmin
$pgadminSecretArgs = @(
    "create", "secret", "generic", "pgadmin-secret", "-n", $DatabaseNamespace,
    "--type=Opaque",
    "--from-literal=PGADMIN_DEFAULT_EMAIL=admin@admin.com",
    "--from-literal=PGADMIN_DEFAULT_PASSWORD=admin123",
    "--dry-run=client", "-o", "yaml"
)
kubectl @pgadminSecretArgs | kubectl apply -f -

# Secret do LocalStack
$localstackSecretArgs = @(
    "create", "secret", "generic", "localstack-secret", "-n", $LocalstackNamespace,
    "--type=Opaque",
    "--from-literal=LOCALSTACK_AUTH_TOKEN=$($env:LOCALSTACK_AUTH_TOKEN)",
    "--from-literal=AWS_ACCESS_KEY_ID=test",
    "--from-literal=AWS_SECRET_ACCESS_KEY=test",
    "--from-literal=AWS_SESSION_TOKEN=",
    "--dry-run=client", "-o", "yaml"
)
kubectl @localstackSecretArgs | kubectl apply -f -

# Secret do Zabbix
$zabbixSecretArgs = @(
    "create", "secret", "generic", "postgres-secret", "-n", $MonitoringNamespace,
    "--type=Opaque",
    "--from-literal=POSTGRES_USER=zabbix",
    "--from-literal=POSTGRES_PASSWORD=zabbix_pwd",
    "--from-literal=POSTGRES_DB=zabbix",
    "--dry-run=client", "-o", "yaml"
)
kubectl @zabbixSecretArgs | kubectl apply -f -

# ConfigMap de datasources do Grafana (montado em /etc/grafana/provisioning/datasources
# pelo grafana-deployment). Fica aqui porque *configmap.yaml esta no .gitignore.
$grafanaDatasources = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: $MonitoringNamespace
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090/
        isDefault: true
        editable: true
      - name: Tempo
        type: tempo
        access: proxy
        url: http://tempo:3200/
        editable: true
"@
$grafanaDatasources | kubectl apply -f -

Write-Host "Recursos aplicados com sucesso." -ForegroundColor Green