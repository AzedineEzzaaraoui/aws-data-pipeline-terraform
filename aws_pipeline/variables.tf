variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Project name used for tagging resources"
  type        = string
  default     = "analytics-pipeline"
}

variable "bucket_name" {
  description = "S3 bucket for data lake (raw + processed)"
  type        = string
  default     = "analytics-bucket-azedine-12345"
}