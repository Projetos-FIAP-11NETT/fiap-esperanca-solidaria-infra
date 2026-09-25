#
# IAM ROLE
#
resource "aws_iam_role" "lambda_role" {
  name = "lambda-authorizer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

#
# LAMBDA AUTHORIZER
#
resource "aws_lambda_function" "authorizer" {
  function_name    = var.lambda_name
  filename         = "${path.module}/../lambda-auth/function.zip"
  source_code_hash = filebase64sha256("${path.module}/../lambda-auth/function.zip")
  role             = aws_iam_role.lambda_role.arn
  runtime          = "dotnet10"
  handler          = "FiapEsperancaSolidaria.Lambda.Authorizer::FiapEsperancaSolidaria.Lambda.Authorizer.AuthorizerFunction::FunctionHandler"
  timeout          = 60
  memory_size      = 1024

  snap_start {
    apply_on = "None"
  }

  # O LocalStack nao reporta o bloco snap_start de forma estavel (fica alternando
  # ausente/presente entre applies), o que quebra o hash de redeploy do gateway
  # la embaixo ("Provider produced inconsistent final plan"). Nao afeta o
  # comportamento real: LocalStack nao implementa SnapStart de verdade.
  lifecycle {
    ignore_changes = [snap_start]
  }

  environment {
    variables = merge(
      {
        ALLOW_DEV_STAGE_BYPASS = var.allow_dev_stage_bypass
      },
      var.firebase_project_id != "" ? {
        FIREBASE_PROJECT_ID = var.firebase_project_id
      } : {},
      var.jwks_metadata_address != "" ? {
        JWKS_METADATA_ADDRESS = var.jwks_metadata_address
      } : {}
    )
  }
}

#
# API GATEWAY
#
# Dispara a criação via linha de comando pura (sem waiter)

resource "terraform_data" "api_gateway_custom" {
  input = var.api_name

  provisioner "local-exec" {
    # --binary-media-types: o upload de foto de perfil (POST /users/api/v1/User/images) manda
    # multipart/form-data com bytes de imagem — sem isso o gateway trata o corpo como texto
    # UTF-8 e corrompe a imagem antes de chegar na usuario-api.
    command = "aws apigateway create-rest-api --name ${self.input} --region ${data.aws_region.current.name} --endpoint-url http://localhost:30466 --binary-media-types 'multipart/form-data'"
  }
}

# Captura o ID gerado para você usar no restante do seu código HCL
data "aws_api_gateway_rest_api" "main" {
  name       = var.api_name
  depends_on = [terraform_data.api_gateway_custom]
}

data "aws_region" "current" {}

#
# AUTHORIZER
#
resource "aws_api_gateway_authorizer" "lambda_authorizer" {
  name                             = "lambda-authorizer"
  rest_api_id                      = data.aws_api_gateway_rest_api.main.id
  type                             = "TOKEN"
  authorizer_uri                   = aws_lambda_function.authorizer.invoke_arn
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = 0
}

locals {
  dev_stage_bypass_enabled = var.allow_dev_stage_bypass == "true"

  authorization_type = local.dev_stage_bypass_enabled ? "NONE" : "CUSTOM"

  authorizer_id = local.dev_stage_bypass_enabled ? null : aws_api_gateway_authorizer.lambda_authorizer.id

  services = {
    users = {
      path_prefix  = "users"
    }
  }

  public_users_enabled = !local.dev_stage_bypass_enabled
}

resource "aws_api_gateway_resource" "service" {
  for_each    = local.services
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = data.aws_api_gateway_rest_api.main.root_resource_id
  path_part   = each.value.path_prefix
}

# ========================
# CAMPAIGN PUBLIC AND MANAGER RESOURCES
# ========================

resource "aws_api_gateway_resource" "api" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = data.aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "api_v1" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "campaigns_public" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "campanhas"
}

resource "aws_api_gateway_resource" "campaign_id" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.campaigns_public.id
  path_part   = "{id}"
}

resource "aws_api_gateway_resource" "health" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = data.aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_method" "campaigns_public_get" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaigns_public.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "campaigns_public_get" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.campaigns_public.id
  http_method             = aws_api_gateway_method.campaigns_public_get.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Campaign/public"
}

resource "aws_api_gateway_method" "campaigns_post" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaigns_public.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id
}

resource "aws_api_gateway_integration" "campaigns_post" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.campaigns_public.id
  http_method             = aws_api_gateway_method.campaigns_post.http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Campaign"
}

resource "aws_api_gateway_method" "campaigns_public_options" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaigns_public.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "campaigns_public_options" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaigns_public.id
  http_method = aws_api_gateway_method.campaigns_public_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "campaigns_public_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaigns_public.id
  http_method = aws_api_gateway_method.campaigns_public_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "campaigns_public_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaigns_public.id
  http_method = aws_api_gateway_method.campaigns_public_options.http_method
  status_code = aws_api_gateway_method_response.campaigns_public_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.campaigns_public_options]
}

resource "aws_api_gateway_method" "campaign_id_get" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaign_id.id
  http_method   = "GET"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "campaign_id_get" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.campaign_id.id
  http_method             = aws_api_gateway_method.campaign_id_get.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Campaign/{id}"

  request_parameters = {
    "integration.request.path.id" = "method.request.path.id"
  }
}

resource "aws_api_gateway_method" "campaign_id_put" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaign_id.id
  http_method   = "PUT"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id

  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "campaign_id_put" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.campaign_id.id
  http_method             = aws_api_gateway_method.campaign_id_put.http_method
  integration_http_method = "PUT"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Campaign/{id}"

  request_parameters = {
    "integration.request.path.id" = "method.request.path.id"
  }
}

resource "aws_api_gateway_method" "campaign_id_options" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaign_id.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "campaign_id_options" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaign_id.id
  http_method = aws_api_gateway_method.campaign_id_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "campaign_id_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaign_id.id
  http_method = aws_api_gateway_method.campaign_id_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "campaign_id_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaign_id.id
  http_method = aws_api_gateway_method.campaign_id_options.http_method
  status_code = aws_api_gateway_method_response.campaign_id_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,PUT,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.campaign_id_options]
}

# ========================
# PROTECTED CAMPAIGN RESOURCES: /api/v1/campanhas/gestao, /images, /{id}/cancel
# ========================
# Espelha CampaignController.List/UploadImage/Cancel (GestorONG) — ver o comentário em
# AuthorizationRulesService.InitializeRulesStatic() no lambda-authorizer, que já apontava
# essa lacuna.

resource "aws_api_gateway_resource" "campaigns_gestao" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.campaigns_public.id
  path_part   = "gestao"
}

resource "aws_api_gateway_method" "campaigns_gestao_get" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaigns_gestao.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id
}

resource "aws_api_gateway_integration" "campaigns_gestao_get" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.campaigns_gestao.id
  http_method             = aws_api_gateway_method.campaigns_gestao_get.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Campaign"
}

resource "aws_api_gateway_method" "campaigns_gestao_options" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaigns_gestao.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "campaigns_gestao_options" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaigns_gestao.id
  http_method = aws_api_gateway_method.campaigns_gestao_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "campaigns_gestao_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaigns_gestao.id
  http_method = aws_api_gateway_method.campaigns_gestao_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "campaigns_gestao_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaigns_gestao.id
  http_method = aws_api_gateway_method.campaigns_gestao_options.http_method
  status_code = aws_api_gateway_method_response.campaigns_gestao_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.campaigns_gestao_options]
}

# --- /api/v1/campanhas/images ---

resource "aws_api_gateway_resource" "campaigns_images" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.campaigns_public.id
  path_part   = "images"
}

resource "aws_api_gateway_method" "campaigns_images_post" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaigns_images.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id
}

resource "aws_api_gateway_integration" "campaigns_images_post" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.campaigns_images.id
  http_method             = aws_api_gateway_method.campaigns_images_post.http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Campaign/images"
  # CONVERT_TO_BINARY (mesmo motivo do upload de foto de perfil em users_images_public):
  # o corpo é multipart/form-data com a imagem de capa da campanha.
  content_handling = "CONVERT_TO_BINARY"
}

resource "aws_api_gateway_method" "campaigns_images_options" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaigns_images.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "campaigns_images_options" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaigns_images.id
  http_method = aws_api_gateway_method.campaigns_images_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "campaigns_images_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaigns_images.id
  http_method = aws_api_gateway_method.campaigns_images_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "campaigns_images_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaigns_images.id
  http_method = aws_api_gateway_method.campaigns_images_options.http_method
  status_code = aws_api_gateway_method_response.campaigns_images_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.campaigns_images_options]
}

# --- /api/v1/campanhas/{id}/cancel ---

resource "aws_api_gateway_resource" "campaign_id_cancel" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.campaign_id.id
  path_part   = "cancel"
}

resource "aws_api_gateway_method" "campaign_id_cancel_post" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaign_id_cancel.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id

  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "campaign_id_cancel_post" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.campaign_id_cancel.id
  http_method             = aws_api_gateway_method.campaign_id_cancel_post.http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Campaign/{id}/cancel"

  request_parameters = {
    "integration.request.path.id" = "method.request.path.id"
  }
}

resource "aws_api_gateway_method" "campaign_id_cancel_options" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.campaign_id_cancel.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "campaign_id_cancel_options" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaign_id_cancel.id
  http_method = aws_api_gateway_method.campaign_id_cancel_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "campaign_id_cancel_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaign_id_cancel.id
  http_method = aws_api_gateway_method.campaign_id_cancel_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "campaign_id_cancel_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.campaign_id_cancel.id
  http_method = aws_api_gateway_method.campaign_id_cancel_options.http_method
  status_code = aws_api_gateway_method_response.campaign_id_cancel_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.campaign_id_cancel_options]
}

resource "aws_api_gateway_method" "health_get" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.health.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "health_get" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.health.id
  http_method             = aws_api_gateway_method.health_get.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/health"
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${data.aws_api_gateway_rest_api.main.execution_arn}/*/*/*"
}

# ========================
# PUBLIC RESOURCES: /users/api/v1/User
# ========================

resource "aws_api_gateway_resource" "users_api_public" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.service["users"].id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "users_v1_public" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users_api_public[0].id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "users_user_public" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users_v1_public[0].id
  path_part   = "User"
}

# A usuario-api separou o cadastro público de doador (aqui) do de gestor
# (POST /User/GestorONG, exige estar logado como GestorONG — sem rota no
# gateway hoje, o front não usa) — POST /User sozinho não existe mais.
resource "aws_api_gateway_resource" "users_doador_public" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users_user_public[0].id
  path_part   = "Doador"
}

resource "aws_api_gateway_method" "users_doador_public_post" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_doador_public[0].id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "users_doador_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_doador_public[0].id
  http_method = aws_api_gateway_method.users_doador_public_post[0].http_method
  status_code = "200"
}

resource "aws_api_gateway_integration" "users_doador_public_post" {
  count                   = local.public_users_enabled ? 1 : 0
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_doador_public[0].id
  http_method             = aws_api_gateway_method.users_doador_public_post[0].http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://users-api.apps.svc.cluster.local:${var.container_port}/api/v1/User/Doador"
  content_handling        = "CONVERT_TO_TEXT"
}

resource "aws_api_gateway_integration_response" "users_doador_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_doador_public[0].id
  http_method = aws_api_gateway_method.users_doador_public_post[0].http_method
  status_code = aws_api_gateway_method_response.users_doador_public_post_200[0].status_code

  depends_on = [aws_api_gateway_integration.users_doador_public_post]
}

resource "aws_api_gateway_method" "users_doador_public_options" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_doador_public[0].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_doador_public_options" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_doador_public[0].id
  http_method = aws_api_gateway_method.users_doador_public_options[0].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

# Sem method_response/integration_response aqui, o MOCK não tem pra onde
# mapear a resposta e o LocalStack devolve 500 ApiConfigurationException no
# preflight — é isso que travava qualquer POST/PUT/DELETE do navegador.
resource "aws_api_gateway_method_response" "users_doador_public_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_doador_public[0].id
  http_method = aws_api_gateway_method.users_doador_public_options[0].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "users_doador_public_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_doador_public[0].id
  http_method = aws_api_gateway_method.users_doador_public_options[0].http_method
  status_code = aws_api_gateway_method_response.users_doador_public_options_200[0].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.users_doador_public_options]
}

# ========================
# PUBLIC RESOURCES: /users/api/v1/User/images
# ========================
# Upload de foto de perfil. Anônimo de propósito, igual ao endpoint na usuario-api: no
# cadastro ainda não existe conta pra autenticar contra (ver UserController.UploadImageAsync).

resource "aws_api_gateway_resource" "users_images_public" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users_user_public[0].id
  path_part   = "images"
}

resource "aws_api_gateway_method" "users_images_public_post" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_images_public[0].id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "users_images_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_images_public[0].id
  http_method = aws_api_gateway_method.users_images_public_post[0].http_method
  status_code = "200"
}

resource "aws_api_gateway_integration" "users_images_public_post" {
  count                   = local.public_users_enabled ? 1 : 0
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_images_public[0].id
  http_method             = aws_api_gateway_method.users_images_public_post[0].http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://users-api.apps.svc.cluster.local:${var.container_port}/api/v1/User/images"
  # CONVERT_TO_BINARY (não CONVERT_TO_TEXT como o /User acima): o corpo é
  # multipart/form-data com uma imagem, precisa chegar intacto na usuario-api.
  content_handling = "CONVERT_TO_BINARY"
}

resource "aws_api_gateway_integration_response" "users_images_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_images_public[0].id
  http_method = aws_api_gateway_method.users_images_public_post[0].http_method
  status_code = aws_api_gateway_method_response.users_images_public_post_200[0].status_code

  depends_on = [aws_api_gateway_integration.users_images_public_post]
}

resource "aws_api_gateway_method" "users_images_public_options" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_images_public[0].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_images_public_options" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_images_public[0].id
  http_method = aws_api_gateway_method.users_images_public_options[0].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "users_images_public_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_images_public[0].id
  http_method = aws_api_gateway_method.users_images_public_options[0].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "users_images_public_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_images_public[0].id
  http_method = aws_api_gateway_method.users_images_public_options[0].http_method
  status_code = aws_api_gateway_method_response.users_images_public_options_200[0].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.users_images_public_options]
}

# ========================
# PUBLIC RESOURCES: /users/api/v1/User/Login
# ========================

resource "aws_api_gateway_resource" "users_login_public" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users_user_public[0].id
  path_part   = "Login"
}

resource "aws_api_gateway_method" "users_login_public_post" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_login_public[0].id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "users_login_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_login_public[0].id
  http_method = aws_api_gateway_method.users_login_public_post[0].http_method
  status_code = "200"
}

resource "aws_api_gateway_integration" "users_login_public_post" {
  count                   = local.public_users_enabled ? 1 : 0
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_login_public[0].id
  http_method             = aws_api_gateway_method.users_login_public_post[0].http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://users-api.apps.svc.cluster.local:${var.container_port}/api/v1/User/Login"
  content_handling        = "CONVERT_TO_TEXT"
}

resource "aws_api_gateway_integration_response" "users_login_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_login_public[0].id
  http_method = aws_api_gateway_method.users_login_public_post[0].http_method
  status_code = aws_api_gateway_method_response.users_login_public_post_200[0].status_code

  depends_on = [aws_api_gateway_integration.users_login_public_post]
}

resource "aws_api_gateway_method" "users_login_public_options" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_login_public[0].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_login_public_options" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_login_public[0].id
  http_method = aws_api_gateway_method.users_login_public_options[0].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "users_login_public_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_login_public[0].id
  http_method = aws_api_gateway_method.users_login_public_options[0].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "users_login_public_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_login_public[0].id
  http_method = aws_api_gateway_method.users_login_public_options[0].http_method
  status_code = aws_api_gateway_method_response.users_login_public_options_200[0].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.users_login_public_options]
}

# ========================
# PUBLIC RESOURCES: /users/api/v1/User/RefreshToken
# ========================
# Sem [Authorize] na usuario-api — a credencial é o par sessionId+refreshToken no corpo,
# não um Bearer (ver RefreshTokenCommandHandler). Cada chamada renova a sessão no servidor
# por mais 1h (SessionLifetime.Duration), então o front pode evitar o logout forçado.

resource "aws_api_gateway_resource" "users_refresh_token_public" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users_user_public[0].id
  path_part   = "RefreshToken"
}

resource "aws_api_gateway_method" "users_refresh_token_public_post" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_refresh_token_public[0].id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "users_refresh_token_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_refresh_token_public[0].id
  http_method = aws_api_gateway_method.users_refresh_token_public_post[0].http_method
  status_code = "200"
}

resource "aws_api_gateway_integration" "users_refresh_token_public_post" {
  count                   = local.public_users_enabled ? 1 : 0
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_refresh_token_public[0].id
  http_method             = aws_api_gateway_method.users_refresh_token_public_post[0].http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://users-api.apps.svc.cluster.local:${var.container_port}/api/v1/User/RefreshToken"
  content_handling        = "CONVERT_TO_TEXT"
}

resource "aws_api_gateway_integration_response" "users_refresh_token_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_refresh_token_public[0].id
  http_method = aws_api_gateway_method.users_refresh_token_public_post[0].http_method
  status_code = aws_api_gateway_method_response.users_refresh_token_public_post_200[0].status_code

  depends_on = [aws_api_gateway_integration.users_refresh_token_public_post]
}

resource "aws_api_gateway_method" "users_refresh_token_public_options" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_refresh_token_public[0].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_refresh_token_public_options" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_refresh_token_public[0].id
  http_method = aws_api_gateway_method.users_refresh_token_public_options[0].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "users_refresh_token_public_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_refresh_token_public[0].id
  http_method = aws_api_gateway_method.users_refresh_token_public_options[0].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "users_refresh_token_public_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_refresh_token_public[0].id
  http_method = aws_api_gateway_method.users_refresh_token_public_options[0].http_method
  status_code = aws_api_gateway_method_response.users_refresh_token_public_options_200[0].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.users_refresh_token_public_options]
}

# ========================
# PROTECTED RESOURCES: /users/api/v1/User/Session/{sessionId}
# ========================

resource "aws_api_gateway_resource" "users_session_public" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users_user_public[0].id
  path_part   = "Session"
}

resource "aws_api_gateway_resource" "users_session_id" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users_session_public[0].id
  path_part   = "{sessionId}"
}

resource "aws_api_gateway_method" "users_session_get" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_session_id[0].id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id

  request_parameters = {
    "method.request.path.sessionId" = true
  }
}

resource "aws_api_gateway_integration" "users_session_get" {
  count                   = local.public_users_enabled ? 1 : 0
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_session_id[0].id
  http_method             = aws_api_gateway_method.users_session_get[0].http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://users-api.apps.svc.cluster.local:${var.container_port}/api/v1/User/Session/{sessionId}"

  request_parameters = {
    "integration.request.path.sessionId" = "method.request.path.sessionId"
  }
}

resource "aws_api_gateway_method" "users_session_delete" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_session_id[0].id
  http_method   = "DELETE"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id

  request_parameters = {
    "method.request.path.sessionId" = true
  }
}

resource "aws_api_gateway_integration" "users_session_delete" {
  count                   = local.public_users_enabled ? 1 : 0
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_session_id[0].id
  http_method             = aws_api_gateway_method.users_session_delete[0].http_method
  integration_http_method = "DELETE"
  type                    = "HTTP_PROXY"
  uri                     = "http://users-api.apps.svc.cluster.local:${var.container_port}/api/v1/User/Session/{sessionId}"

  request_parameters = {
    "integration.request.path.sessionId" = "method.request.path.sessionId"
  }
}

resource "aws_api_gateway_method" "users_session_options" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_session_id[0].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_session_options" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_session_id[0].id
  http_method = aws_api_gateway_method.users_session_options[0].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "users_session_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_session_id[0].id
  http_method = aws_api_gateway_method.users_session_options[0].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "users_session_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_session_id[0].id
  http_method = aws_api_gateway_method.users_session_options[0].http_method
  status_code = aws_api_gateway_method_response.users_session_options_200[0].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.users_session_options]
}

# ========================
# PROTECTED RESOURCE: /users/api/v1/User/MakeGestorONG
# ========================

resource "aws_api_gateway_resource" "users_make_gestor_ong" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users_user_public[0].id
  path_part   = "MakeGestorONG"
}

resource "aws_api_gateway_method" "users_make_gestor_ong_put" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_make_gestor_ong[0].id
  http_method   = "PUT"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id
}

resource "aws_api_gateway_integration" "users_make_gestor_ong_put" {
  count                   = local.public_users_enabled ? 1 : 0
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_make_gestor_ong[0].id
  http_method             = aws_api_gateway_method.users_make_gestor_ong_put[0].http_method
  integration_http_method = "PUT"
  type                    = "HTTP_PROXY"
  uri                     = "http://users-api.apps.svc.cluster.local:${var.container_port}/api/v1/User/MakeGestorONG"
}

resource "aws_api_gateway_method" "users_make_gestor_ong_options" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_make_gestor_ong[0].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_make_gestor_ong_options" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_make_gestor_ong[0].id
  http_method = aws_api_gateway_method.users_make_gestor_ong_options[0].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "users_make_gestor_ong_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_make_gestor_ong[0].id
  http_method = aws_api_gateway_method.users_make_gestor_ong_options[0].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "users_make_gestor_ong_options_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_make_gestor_ong[0].id
  http_method = aws_api_gateway_method.users_make_gestor_ong_options[0].http_method
  status_code = aws_api_gateway_method_response.users_make_gestor_ong_options_200[0].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'PUT,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.users_make_gestor_ong_options]
}

# ========================
# DONATION RESOURCES: /api/v1/doacoes(/me | /{id})
# ========================
# Antes desta seção, o campanha-api não tinha rota nenhuma no gateway pra
# Donation (só Campaign/health/users) — ver o comentário em
# AuthorizationRulesService.InitializeRulesStatic() no lambda-authorizer, que
# já apontava essa lacuna.

resource "aws_api_gateway_resource" "donations_public" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "doacoes"
}

resource "aws_api_gateway_method" "donations_post" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.donations_public.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id
}

resource "aws_api_gateway_integration" "donations_post" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.donations_public.id
  http_method             = aws_api_gateway_method.donations_post.http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Donation"
}

resource "aws_api_gateway_method" "donations_options" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.donations_public.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "donations_options" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.donations_public.id
  http_method = aws_api_gateway_method.donations_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "donations_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.donations_public.id
  http_method = aws_api_gateway_method.donations_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "donations_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.donations_public.id
  http_method = aws_api_gateway_method.donations_options.http_method
  status_code = aws_api_gateway_method_response.donations_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.donations_options]
}

# --- /api/v1/doacoes/me ---

resource "aws_api_gateway_resource" "donation_me" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.donations_public.id
  path_part   = "me"
}

resource "aws_api_gateway_method" "donation_me_get" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.donation_me.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id
}

resource "aws_api_gateway_integration" "donation_me_get" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.donation_me.id
  http_method             = aws_api_gateway_method.donation_me_get.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Donation/me"
}

resource "aws_api_gateway_method" "donation_me_options" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.donation_me.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "donation_me_options" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.donation_me.id
  http_method = aws_api_gateway_method.donation_me_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "donation_me_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.donation_me.id
  http_method = aws_api_gateway_method.donation_me_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "donation_me_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.donation_me.id
  http_method = aws_api_gateway_method.donation_me_options.http_method
  status_code = aws_api_gateway_method_response.donation_me_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.donation_me_options]
}

# --- /api/v1/doacoes/{id} ---

resource "aws_api_gateway_resource" "donation_id" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.donations_public.id
  path_part   = "{id}"
}

resource "aws_api_gateway_method" "donation_id_get" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.donation_id.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.lambda_authorizer.id

  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "donation_id_get" {
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.donation_id.id
  http_method             = aws_api_gateway_method.donation_id_get.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://campaigns-api.apps.svc.cluster.local:${var.container_port}/api/v1/Donation/{id}"

  request_parameters = {
    "integration.request.path.id" = "method.request.path.id"
  }
}

resource "aws_api_gateway_method" "donation_id_options" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.donation_id.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "donation_id_options" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.donation_id.id
  http_method = aws_api_gateway_method.donation_id_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "donation_id_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.donation_id.id
  http_method = aws_api_gateway_method.donation_id_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "donation_id_options_200" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.donation_id.id
  http_method = aws_api_gateway_method.donation_id_options.http_method
  status_code = aws_api_gateway_method_response.donation_id_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.donation_id_options]
}

# ========================
# CORS NAS RESPOSTAS DE ERRO GERADAS PELO PRÓPRIO GATEWAY
# ========================
# Quando o authorizer nega (403 "explicit deny"), quem responde é o gateway, não
# o backend — então não passa pelo middleware de CORS do campanha-api. Sem estes
# headers o navegador esconde o erro ("Failed to fetch") e o front não
# consegue distinguir token expirado/inválido de API fora do ar.

resource "aws_api_gateway_gateway_response" "cors" {
  for_each      = toset(["UNAUTHORIZED", "ACCESS_DENIED", "DEFAULT_4XX", "DEFAULT_5XX"])
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  response_type = each.key

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "gatewayresponse.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
  }
}

# ========================
# DEPLOYMENT
# ========================

resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id

  # Forca um novo deployment sempre que qualquer recurso/metodo/integracao mudar -
  # sem isso, o Terraform so cria o deployment uma vez e edicoes depois nao chegam
  # no stage ate um "terraform apply -replace" manual.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.service,
      aws_api_gateway_resource.api,
      aws_api_gateway_resource.api_v1,
      aws_api_gateway_resource.campaigns_public,
      aws_api_gateway_resource.campaign_id,
      aws_api_gateway_resource.health,
      aws_api_gateway_method.campaigns_public_get,
      aws_api_gateway_integration.campaigns_public_get,
      aws_api_gateway_method.campaigns_post,
      aws_api_gateway_integration.campaigns_post,
      aws_api_gateway_method.campaign_id_get,
      aws_api_gateway_integration.campaign_id_get,
      aws_api_gateway_method.campaign_id_put,
      aws_api_gateway_integration.campaign_id_put,
      aws_api_gateway_method.health_get,
      aws_api_gateway_integration.health_get,
      # .id (nao o objeto inteiro): aws_lambda_function.authorizer, referenciada aqui via
      # authorizer_uri, tem o snap_start instavel no LocalStack (ver lifecycle acima) — colocar
      # o objeto inteiro no hash quebrava o redeploy com "Provider produced inconsistent final plan".
      aws_api_gateway_authorizer.lambda_authorizer.id,
      aws_api_gateway_method.users_session_get,
      aws_api_gateway_integration.users_session_get,
      aws_api_gateway_method.users_session_delete,
      aws_api_gateway_integration.users_session_delete,
      aws_api_gateway_method.users_make_gestor_ong_put,
      aws_api_gateway_integration.users_make_gestor_ong_put,
      # Doador (cadastro) e RefreshToken (novas, substituem o antigo POST /User unico)
      aws_api_gateway_method.users_doador_public_post,
      aws_api_gateway_integration.users_doador_public_post,
      aws_api_gateway_integration_response.users_doador_public_post_200,
      aws_api_gateway_method.users_refresh_token_public_post,
      aws_api_gateway_integration.users_refresh_token_public_post,
      aws_api_gateway_integration_response.users_refresh_token_public_post_200,
      aws_api_gateway_integration_response.users_refresh_token_public_options_200,
      # CORS (OPTIONS) das rotas que ja existiam
      aws_api_gateway_integration_response.users_doador_public_options_200,
      aws_api_gateway_integration_response.users_login_public_options_200,
      aws_api_gateway_integration_response.users_session_options_200,
      aws_api_gateway_integration_response.users_make_gestor_ong_options_200,
      aws_api_gateway_integration_response.campaigns_public_options_200,
      aws_api_gateway_integration_response.campaign_id_options_200,
      # Lista de .id (nao o objeto inteiro): o LocalStack nao devolve response_templates/status_code
      # de forma estavel pra esse recurso, mesmo problema do snap_start acima ("Provider produced
      # inconsistent final plan" se o objeto inteiro entrar no hash).
      [for r in aws_api_gateway_gateway_response.cors : r.id],
      # Rotas de Donation (novas)
      aws_api_gateway_resource.donations_public,
      aws_api_gateway_resource.donation_me,
      aws_api_gateway_resource.donation_id,
      aws_api_gateway_method.donations_post,
      aws_api_gateway_integration.donations_post,
      aws_api_gateway_integration_response.donations_options_200,
      aws_api_gateway_method.donation_me_get,
      aws_api_gateway_integration.donation_me_get,
      aws_api_gateway_integration_response.donation_me_options_200,
      aws_api_gateway_method.donation_id_get,
      aws_api_gateway_integration.donation_id_get,
      aws_api_gateway_integration_response.donation_id_options_200,
      # Rota de upload de imagem de perfil (nova)
      aws_api_gateway_resource.users_images_public,
      aws_api_gateway_method.users_images_public_post,
      aws_api_gateway_integration.users_images_public_post,
      aws_api_gateway_integration_response.users_images_public_post_200,
      aws_api_gateway_integration_response.users_images_public_options_200,
      # Rotas de gestao de campanha (novas)
      aws_api_gateway_resource.campaigns_gestao,
      aws_api_gateway_method.campaigns_gestao_get,
      aws_api_gateway_integration.campaigns_gestao_get,
      aws_api_gateway_integration_response.campaigns_gestao_options_200,
      aws_api_gateway_resource.campaigns_images,
      aws_api_gateway_method.campaigns_images_post,
      aws_api_gateway_integration.campaigns_images_post,
      aws_api_gateway_integration_response.campaigns_images_options_200,
      aws_api_gateway_resource.campaign_id_cancel,
      aws_api_gateway_method.campaign_id_cancel_post,
      aws_api_gateway_integration.campaign_id_cancel_post,
      aws_api_gateway_integration_response.campaign_id_cancel_options_200,
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.campaigns_public_get,
    aws_api_gateway_integration.campaigns_post,
    aws_api_gateway_integration.campaign_id_get,
    aws_api_gateway_integration.campaign_id_put,
    aws_api_gateway_integration.health_get,
    aws_lambda_permission.api_gateway,
    aws_api_gateway_integration.users_doador_public_post,
    aws_api_gateway_integration.users_doador_public_options,
    aws_api_gateway_integration.users_refresh_token_public_post,
    aws_api_gateway_integration.users_refresh_token_public_options,
    aws_api_gateway_integration_response.users_refresh_token_public_post_200,
    aws_api_gateway_integration_response.users_refresh_token_public_options_200,
    aws_api_gateway_integration.users_login_public_post,
    aws_api_gateway_integration.users_login_public_options,
    aws_api_gateway_integration_response.users_doador_public_post_200,
    aws_api_gateway_integration_response.users_login_public_post_200,
    aws_api_gateway_integration.users_session_get,
    aws_api_gateway_integration.users_session_delete,
    aws_api_gateway_integration.users_session_options,
    aws_api_gateway_integration.users_make_gestor_ong_put,
    aws_api_gateway_integration.users_make_gestor_ong_options,
    aws_api_gateway_integration_response.users_doador_public_options_200,
    aws_api_gateway_integration_response.users_login_public_options_200,
    aws_api_gateway_integration_response.users_session_options_200,
    aws_api_gateway_integration_response.users_make_gestor_ong_options_200,
    aws_api_gateway_integration.campaigns_public_options,
    aws_api_gateway_integration_response.campaigns_public_options_200,
    aws_api_gateway_integration.campaign_id_options,
    aws_api_gateway_integration_response.campaign_id_options_200,
    aws_api_gateway_integration.donations_post,
    aws_api_gateway_integration.donations_options,
    aws_api_gateway_integration_response.donations_options_200,
    aws_api_gateway_integration.donation_me_get,
    aws_api_gateway_integration.donation_me_options,
    aws_api_gateway_integration_response.donation_me_options_200,
    aws_api_gateway_integration.donation_id_get,
    aws_api_gateway_integration.donation_id_options,
    aws_api_gateway_integration_response.donation_id_options_200,
    aws_api_gateway_integration.users_images_public_post,
    aws_api_gateway_integration.users_images_public_options,
    aws_api_gateway_integration.campaigns_gestao_get,
    aws_api_gateway_integration.campaigns_gestao_options,
    aws_api_gateway_integration_response.campaigns_gestao_options_200,
    aws_api_gateway_integration.campaigns_images_post,
    aws_api_gateway_integration.campaigns_images_options,
    aws_api_gateway_integration_response.campaigns_images_options_200,
    aws_api_gateway_integration.campaign_id_cancel_post,
    aws_api_gateway_integration.campaign_id_cancel_options,
    aws_api_gateway_integration_response.campaign_id_cancel_options_200,
    aws_api_gateway_integration_response.users_images_public_options_200,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "stage" {
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  deployment_id = aws_api_gateway_deployment.deploy.id
  stage_name    = var.stage_name
}

# =====================================================
# IAM Role for Lambda
# =====================================================

resource "aws_iam_role" "lambda_notification_role" {
  name = var.iam_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# =====================================================
# IAM Policy for Lambda (SES and SQS permissions)
# =====================================================

resource "aws_iam_role_policy" "lambda_policy" {
  name   = "${var.iam_role_name}-policy"
  role   = aws_iam_role.lambda_notification_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail",
          "ses:GetAccountSendingEnabled",
          "ses:ListVerifiedEmailAddresses",
          "ses:ListIdentities"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.notification_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:000000000000:*"
      }
    ]
  })
}

# =====================================================
# SQS Queue
# =====================================================

resource "aws_sqs_queue" "notification_queue" {
  name = var.sqs_queue_name

  tags = var.tags
}

resource "aws_sqs_queue" "process_donation_queue" {
  name = var.sqs_donation_queue_name

  tags = var.tags
}

# =====================================================
# Lambda Function
# =====================================================

resource "aws_lambda_function" "email_function" {
  filename         = "${path.module}/../lambda-notification/function.zip"
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda_role.arn
  handler          = var.lambda_handler
  runtime          = var.lambda_runtime
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  source_code_hash = filebase64sha256("${path.module}/../lambda-notification/function.zip")

  environment {
    variables = var.lambda_environment_variables
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy.lambda_policy
  ]
}

# =====================================================
# Lambda Event Source Mapping (SQS trigger)
# =====================================================

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.notification_queue.arn
  function_name    = aws_lambda_function.email_function.function_name
  batch_size       = var.sqs_batch_size

  depends_on = [
    aws_lambda_function.email_function
  ]
}

# =====================================================
# SES Email Verification
# =====================================================

resource "aws_ses_email_identity" "notification_email" {
  email = var.ses_verified_email
}
