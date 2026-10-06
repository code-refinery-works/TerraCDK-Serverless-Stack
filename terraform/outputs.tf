output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.main.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.main.arn
}

output "lambda_role_arn" {
  description = "IAM Role ARN for Lambda"
  value       = aws_iam_role.lambda.arn
}

output "lambda_log_group_name" {
  description = "CloudWatch Log Group for Lambda"
  value       = aws_cloudwatch_log_group.lambda.name
}

output "apigw_log_group_name" {
  description = "CloudWatch Log Group for API Gateway access logs"
  value       = aws_cloudwatch_log_group.apigw.name
}

output "ssm_prefix" {
  description = "SSM Parameter Store path prefix used by CDK"
  value       = "/${var.env}/${var.project}"
}