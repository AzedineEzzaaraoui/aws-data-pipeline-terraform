provider "aws" {
  region = var.region
}

# ---------------- S3 DATA LAKE ----------------
resource "aws_s3_bucket" "data_lake" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.data_lake.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------- DYNAMODB ----------------
resource "aws_dynamodb_table" "cart_events" {
  name         = "cart_events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"
}

# ---------------- IAM ROLE ----------------
resource "aws_iam_role" "lambda_role" {
  name = "lambda-pipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# ---------------- BASIC LOGS ----------------
resource "aws_iam_role_policy_attachment" "basic_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ---------------- S3 ACCESS (FIXED - LEAST PRIVILEGE) ----------------
resource "aws_iam_policy" "s3_policy" {
  name = "lambda-s3-access"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.s3_policy.arn
}

# ---------------- DYNAMODB STREAM ACCESS (FIXED) ----------------
resource "aws_iam_policy" "dynamodb_stream_policy" {
  name = "lambda-dynamodb-stream-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "dynamodb:DescribeStream",
        "dynamodb:GetRecords",
        "dynamodb:GetShardIterator",
        "dynamodb:ListStreams"
      ],
      Resource = aws_dynamodb_table.cart_events.stream_arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dynamo_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.dynamodb_stream_policy.arn
}

# ---------------- LAMBDA 1: STREAM TO S3 ----------------
data "archive_file" "stream_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/stream_to_s3.py"
  output_path = "${path.module}/lambda/stream.zip"
}

resource "aws_lambda_function" "stream_to_s3" {
  function_name = "stream-to-s3"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.12"
  handler       = "stream_to_s3.lambda_handler"

  filename         = data.archive_file.stream_zip.output_path
  source_code_hash = data.archive_file.stream_zip.output_base64sha256

  timeout     = 15
  memory_size = 128

  environment {
    variables = {
      BUCKET = var.bucket_name
    }
  }
}

# DynamoDB trigger (FIXED + safe config)
resource "aws_lambda_event_source_mapping" "dynamo_trigger" {
  event_source_arn  = aws_dynamodb_table.cart_events.stream_arn
  function_name      = aws_lambda_function.stream_to_s3.arn
  starting_position  = "LATEST"
  batch_size         = 100

  depends_on = [aws_dynamodb_table.cart_events]
}

# ---------------- LAMBDA 2: TRANSFORM ----------------
data "archive_file" "transform_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/transform_daily.py"
  output_path = "${path.module}/lambda/transform.zip"
}

resource "aws_lambda_function" "transform_daily" {
  function_name = "transform-daily"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.12"
  handler       = "transform_daily.lambda_handler"

  filename         = data.archive_file.transform_zip.output_path
  source_code_hash = data.archive_file.transform_zip.output_base64sha256

  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      BUCKET = var.bucket_name
    }
  }
}

# ---------------- EVENTBRIDGE SCHEDULE ----------------
resource "aws_cloudwatch_event_rule" "daily" {
  name                = "daily-transform"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule = aws_cloudwatch_event_rule.daily.name
  arn  = aws_lambda_function.transform_daily.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transform_daily.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily.arn
}