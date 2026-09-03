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
  filename         = "${path.module}/lambda-auth/function.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda-auth/function.zip")
  role             = aws_iam_role.lambda_role.arn
  runtime          = "dotnet10"
  handler          = "FiapEsperancaSolidaria.Lambda.Authorizer::FiapEsperancaSolidaria.Lambda.Authorizer.AuthorizerFunction::FunctionHandler"
  timeout          = 60
  memory_size      = 1024

  snap_start {
    apply_on = "None"
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
    command = "aws apigateway create-rest-api --name ${self.input} --region ${data.aws_region.current.name} --endpoint-url http://localhost:30466"
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
  uri                     = "http://campaigns-api:${var.container_port}/api/v1/campanhas/publicas"
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
  uri                     = "http://campaigns-api:${var.container_port}/api/v1/campanhas"
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
  uri                     = "http://campaigns-api:${var.container_port}/api/v1/campanhas/{id}"

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
  uri                     = "http://campaigns-api:${var.container_port}/api/v1/campanhas/{id}"

  request_parameters = {
    "integration.request.path.id" = "method.request.path.id"
  }
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
  uri                     = "http://campaigns-api:${var.container_port}/health"
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

resource "aws_api_gateway_method" "users_user_public_post" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_user_public[0].id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "users_user_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_user_public[0].id
  http_method = aws_api_gateway_method.users_user_public_post[0].http_method
  status_code = "200"
}

resource "aws_api_gateway_integration" "users_user_public_post" {
  count                   = local.public_users_enabled ? 1 : 0
  rest_api_id             = data.aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_user_public[0].id
  http_method             = aws_api_gateway_method.users_user_public_post[0].http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://users-api:${var.container_port}/api/v1/User"
  content_handling        = "CONVERT_TO_TEXT"
}

resource "aws_api_gateway_integration_response" "users_user_public_post_200" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_user_public[0].id
  http_method = aws_api_gateway_method.users_user_public_post[0].http_method
  status_code = aws_api_gateway_method_response.users_user_public_post_200[0].status_code

  depends_on = [aws_api_gateway_integration.users_user_public_post]
}

resource "aws_api_gateway_method" "users_user_public_options" {
  count         = local.public_users_enabled ? 1 : 0
  rest_api_id   = data.aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_user_public[0].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_user_public_options" {
  count       = local.public_users_enabled ? 1 : 0
  rest_api_id = data.aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_user_public[0].id
  http_method = aws_api_gateway_method.users_user_public_options[0].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
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
  uri                     = "http://users-api:${var.container_port}/api/v1/User/Login"
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

# ========================
# DEPLOYMENT
# ========================

resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = data.aws_api_gateway_rest_api.main.id

  depends_on = [
    aws_api_gateway_integration.campaigns_public_get,
    aws_api_gateway_integration.campaigns_post,
    aws_api_gateway_integration.campaign_id_get,
    aws_api_gateway_integration.campaign_id_put,
    aws_api_gateway_integration.health_get,
    aws_lambda_permission.api_gateway,
    aws_api_gateway_integration.users_user_public_post,
    aws_api_gateway_integration.users_user_public_options,
    aws_api_gateway_integration.users_login_public_post,
    aws_api_gateway_integration.users_login_public_options,
    aws_api_gateway_integration_response.users_user_public_post_200,
    aws_api_gateway_integration_response.users_login_public_post_200,
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
  filename         = "${path.module}/lambda-notification/function.zip"
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda_role.arn
  handler          = var.lambda_handler
  runtime          = var.lambda_runtime
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  source_code_hash = filebase64sha256("${path.module}/lambda-notification/function.zip")

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
