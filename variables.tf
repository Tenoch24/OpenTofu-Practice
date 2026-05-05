variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for tagging and resource naming"
  type        = string
  default     = "ticket-classifier"
}

variable "bucket_name" {
  description = "S3 bucket name for storing classified tickets"
  type        = string
  default     = "ticket-classifier-pipeline"
}
