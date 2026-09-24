variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "stage_name" {
  type    = string
  default = "dev"
}

variable "api_name" {
  type    = string
  default = "local-api-gateway-v1"
}

variable "lambda_name" {
  type    = string
  default = "fiap-api-authorizer"
}

variable "allow_dev_stage_bypass" {
  type    = string
  default = "false"
}

variable "container_port" {
  type    = string
  default = "8080"
}

variable "firebase_project_id" {
  type    = string
  default = ""
}

variable "jwks_metadata_address" {
  type    = string
  default = ""
}

variable "localstack_port" {
  type    = string
  default = "30466"
}


variable "aws_access_key" {
  description = "AWS access key (for LocalStack)"
  type        = string
  sensitive   = true
  default     = "test"
}

variable "aws_secret_key" {
  description = "AWS secret key (for LocalStack)"
  type        = string
  sensitive   = true
  default     = "test"
}

variable "localstack_endpoint" {
  description = "LocalStack endpoint URL"
  type        = string
  default     = "http://localhost:30466"
}

# Lambda Configuration
variable "lambda_function_name" {
  description = "Name of the Lambda function"
  type        = string
  default     = "email-function"
}

variable "lambda_runtime" {
  description = "Lambda runtime"
  type        = string
  default     = "dotnet8"
}

variable "lambda_memory_size" {
  description = "Lambda memory size in MB"
  type        = number
  default     = 512
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 30
}

variable "lambda_handler" {
  description = "Lambda handler"
  type        = string
  default     = "FiapEsperancaSolidaria.Notifications.Lambda::FiapEsperancaSolidaria.Notifications.Lambda.EmailFunction::FunctionHandler"
}

# IAM Configuration
variable "iam_role_name" {
  description = "Name of the IAM role for Lambda"
  type        = string
  default     = "lambda-role"
}

# SQS Configuration
variable "sqs_queue_name" {
  description = "Name of the SQS notification queue"
  type        = string
  default     = "notification-queue"
}

variable "sqs_donation_queue_name" {
  description = "Name of the SQS process donation queue"
  type        = string
  default     = "process-donation-payment"
}

variable "sqs_batch_size" {
  description = "Batch size for SQS Lambda trigger"
  type        = number
  default     = 1
}

# Environment Variables
variable "lambda_environment_variables" {
  description = "Environment variables for Lambda function"
  type        = map(string)
  default = {
    AWS_ACCESS_KEY_ID       = "test"
    AWS_SECRET_ACCESS_KEY   = "test"
    AWS_SES_ENDPOINT        = "http://host.docker.internal:4566"
    AWS_REGION              = "us-east-1"
  }
}

# SES Configuration
variable "ses_verified_email" {
  description = "Email address to verify in SES"
  type        = string
  default     = "no-reply@fiapcloudgames.local"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Project = "FiapCloudGames"
    Service = "Notifications"
    Environment = "local"
  }
}
