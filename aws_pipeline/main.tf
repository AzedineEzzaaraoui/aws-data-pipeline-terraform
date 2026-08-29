terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket         = "azedine-tfstate-backend"
    key            = "aws_pipeline/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}

# ---------------- S3 DATA LAKE ----------------
resource "aws_s3_bucket" "data_lake" {
  bucket        = var.bucket_name
  force_destroy = true

  tags = {
    Project = var.project
    Env     = "dev"
  }
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.data_lake.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Chiffrement par défaut (manquant dans la version initiale)
resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Blocage accès public (manquant dans la version initiale)
resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cycle de vie : purge des vieilles versions + transition Glacier sur raw/
resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "archive-raw"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

# Structure dossiers S3
resource "aws_s3_object" "folders" {
  for_each = toset([
    "raw/cart_events/",
    "processed/",
    "athena-results/"
  ])

  bucket = aws_s3_bucket.data_lake.id
  key    = each.value
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

  tags = {
    Project = var.project
  }
}

# ---------------- SQS DLQ (manquant dans la version initiale) ----------------
resource "aws_sqs_queue" "stream_dlq" {
  name                      = "${var.project}-stream-dlq"
  message_retention_seconds = 1209600 # 14 jours
}

# ---------------- IAM — RÔLE LAMBDA STREAM (dédié, moindre privilège) ----------------
resource "aws_iam_role" "stream_lambda_role" {
  name = "${var.project}-stream-lambda-role"

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

resource "aws_iam_role_policy_attachment" "stream_basic_logs" {
  role       = aws_iam_role.stream_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "stream_s3_policy" {
  name = "${var.project}-stream-s3-write"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "s3:PutObject"
      ],
      # Scoped au préfixe raw/ uniquement, pas tout le bucket
      Resource = "${aws_s3_bucket.data_lake.arn}/raw/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "stream_s3_attach" {
  role       = aws_iam_role.stream_lambda_role.name
  policy_arn = aws_iam_policy.stream_s3_policy.arn
}

resource "aws_iam_policy" "dynamodb_stream_policy" {
  name = "${var.project}-lambda-dynamodb-stream-policy"

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
  role       = aws_iam_role.stream_lambda_role.name
  policy_arn = aws_iam_policy.dynamodb_stream_policy.arn
}

# Autorisation d'envoyer vers la DLQ en cas d'échec répété
resource "aws_iam_policy" "stream_dlq_policy" {
  name = "${var.project}-stream-dlq-send"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["sqs:SendMessage"],
      Resource = aws_sqs_queue.stream_dlq.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "stream_dlq_attach" {
  role       = aws_iam_role.stream_lambda_role.name
  policy_arn = aws_iam_policy.stream_dlq_policy.arn
}

# ---------------- IAM — RÔLE LAMBDA TRANSFORM (dédié, moindre privilège) ----------------
resource "aws_iam_role" "transform_lambda_role" {
  name = "${var.project}-transform-lambda-role"

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

resource "aws_iam_role_policy_attachment" "transform_basic_logs" {
  role       = aws_iam_role.transform_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "transform_s3_policy" {
  name = "${var.project}-transform-s3-access"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:ListBucket"],
        Resource = aws_s3_bucket.data_lake.arn,
        Condition = {
          StringLike = { "s3:prefix" = ["raw/*"] }
        }
      },
      {
        Effect   = "Allow",
        Action   = ["s3:GetObject"],
        Resource = "${aws_s3_bucket.data_lake.arn}/raw/*"
      },
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "${aws_s3_bucket.data_lake.arn}/processed/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "transform_s3_attach" {
  role       = aws_iam_role.transform_lambda_role.name
  policy_arn = aws_iam_policy.transform_s3_policy.arn
}

# ---------------- CLOUDWATCH LOGS ----------------
resource "aws_cloudwatch_log_group" "stream_logs" {
  name              = "/aws/lambda/${var.project}-stream-to-s3"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "transform_logs" {
  name              = "/aws/lambda/${var.project}-transform-daily"
  retention_in_days = 7
}

# ---------------- LAMBDA 1 : STREAM ----------------
data "archive_file" "stream_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/stream_to_s3.py"
  output_path = "${path.module}/lambda/stream.zip"
}

resource "aws_lambda_function" "stream_to_s3" {
  function_name = "${var.project}-stream-to-s3"
  role          = aws_iam_role.stream_lambda_role.arn
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

  depends_on = [
    aws_iam_role_policy_attachment.stream_basic_logs,
    aws_iam_role_policy_attachment.stream_s3_attach,
    aws_iam_role_policy_attachment.dynamo_attach
  ]
}

# Trigger DynamoDB avec DLQ (manquant dans la version initiale)
resource "aws_lambda_event_source_mapping" "dynamo_trigger" {
  event_source_arn = aws_dynamodb_table.cart_events.stream_arn
  function_name    = aws_lambda_function.stream_to_s3.arn

  starting_position = "LATEST"
  batch_size        = 100

  maximum_retry_attempts         = 3
  bisect_batch_on_function_error = true

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.stream_dlq.arn
    }
  }
}

# ---------------- LAMBDA 2 : TRANSFORM ----------------
data "archive_file" "transform_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/transform_daily.py"
  output_path = "${path.module}/lambda/transform.zip"
}

resource "aws_lambda_function" "transform_daily" {
  function_name = "${var.project}-transform-daily"
  role          = aws_iam_role.transform_lambda_role.arn
  runtime       = "python3.12"
  handler       = "transform_daily.lambda_handler"

  filename         = data.archive_file.transform_zip.output_path
  source_code_hash = data.archive_file.transform_zip.output_base64sha256

  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      BUCKET = var.bucket_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.transform_basic_logs,
    aws_iam_role_policy_attachment.transform_s3_attach
  ]
}

# ---------------- EVENTBRIDGE ----------------
resource "aws_cloudwatch_event_rule" "daily" {
  name                = "${var.project}-daily-transform"
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
