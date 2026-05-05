terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.6.0"
}

provider "aws" {
  region = var.aws_region
}

# ── Build output directory (zips land here) ───────────────────
resource "null_resource" "builds_dir" {
  provisioner "local-exec" {
    command     = "New-Item -ItemType Directory -Force -Path ${path.module}/builds"
    interpreter = ["PowerShell", "-Command"]
  }
}

# ── S3 bucket for routed tickets ──────────────────────────────
resource "aws_s3_bucket" "tickets" {
  bucket        = var.bucket_name
  force_destroy = true # tofu destroy cleans this up

  tags = { Project = var.project_name }
}

resource "aws_s3_bucket_versioning" "tickets" {
  bucket = aws_s3_bucket.tickets.id
  versioning_configuration { status = "Enabled" }
}

# ── Lambda: ticket-validator ──────────────────────────────────
module "lambda_validate" {
  source        = "./modules/lambda_function"
  function_name = "ticket-validator"
  source_dir    = "${path.module}/lambdas/validate"
  role_arn      = aws_iam_role.lambda_exec.arn
  project_tag   = var.project_name
  depends_on    = [null_resource.builds_dir]
}

# ── Lambda: ticket-classifier ─────────────────────────────────
module "lambda_classify" {
  source        = "./modules/lambda_function"
  function_name = "ticket-classifier"
  source_dir    = "${path.module}/lambdas/classify"
  role_arn      = aws_iam_role.lambda_exec.arn
  project_tag   = var.project_name
  depends_on    = [null_resource.builds_dir]
}

# ── Lambda: ticket-router ─────────────────────────────────────
module "lambda_route" {
  source        = "./modules/lambda_function"
  function_name = "ticket-router"
  source_dir    = "${path.module}/lambdas/route"
  role_arn      = aws_iam_role.lambda_exec.arn
  project_tag   = var.project_name
  environment_variables = {
    BUCKET_NAME = var.bucket_name
  }
  depends_on = [null_resource.builds_dir]
}
