terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = var.project, Env = var.env } }
}

locals {
  prefix = "${var.project}-${var.env}"
}

# ── KMS Key for CloudWatch Logs ──────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "logs" {
  description             = "${local.prefix} CloudWatch Logs encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootAccess"
        Effect = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.prefix}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

# ── DynamoDB ─────────────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "main" {
  name         = "${local.prefix}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute { name = "pk"; type = "S" }
  attribute { name = "sk"; type = "S" }

  point_in_time_recovery { enabled = true }

  server_side_encryption {
    enabled = true
    # AWS managed key for DynamoDB (aws/dynamodb)
  }

  lifecycle { prevent_destroy = true }
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.prefix}-handler"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.logs.arn
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${local.prefix}-access"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.logs.arn
}

# ── IAM Role for Lambda ───────────────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "${local.prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_dynamo" {
  name = "${local.prefix}-lambda-dynamo"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
        Resource = [aws_dynamodb_table.main.arn, "${aws_dynamodb_table.main.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

# ── SSM Parameter Store ───────────────────────────────────────────────────────
resource "aws_ssm_parameter" "table_name" {
  name  = "/${var.env}/${var.project}/dynamodb/table-name"
  type  = "String"
  value = aws_dynamodb_table.main.name
}

resource "aws_ssm_parameter" "table_arn" {
  name  = "/${var.env}/${var.project}/dynamodb/table-arn"
  type  = "String"
  value = aws_dynamodb_table.main.arn
}

resource "aws_ssm_parameter" "lambda_role_arn" {
  name  = "/${var.env}/${var.project}/iam/lambda-role-arn"
  type  = "String"
  value = aws_iam_role.lambda.arn
}

resource "aws_ssm_parameter" "lambda_log_group" {
  name  = "/${var.env}/${var.project}/logs/lambda-log-group"
  type  = "String"
  value = aws_cloudwatch_log_group.lambda.name
}

resource "aws_ssm_parameter" "apigw_log_group" {
  name  = "/${var.env}/${var.project}/logs/apigw-log-group"
  type  = "String"
  value = aws_cloudwatch_log_group.apigw.name
}