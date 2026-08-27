output "bucket_name" {
  description = "S3 data lake bucket name"
  value       = aws_s3_bucket.data_lake.bucket
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.data_lake.arn
}

output "dynamodb_table" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.cart_events.name
}

output "stream_arn" {
  description = "DynamoDB stream ARN"
  value       = aws_dynamodb_table.cart_events.stream_arn
}

output "lambda_stream_function" {
  description = "Stream-to-S3 Lambda name"
  value       = aws_lambda_function.stream_to_s3.function_name
}

output "lambda_transform_function" {
  description = "Transform Lambda name"
  value       = aws_lambda_function.transform_daily.function_name
}