variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
}

variable "source_dir" {
  description = "Path to directory containing lambda_function.py"
  type        = string
}

variable "role_arn" {
  description = "IAM execution role ARN"
  type        = string
}

variable "environment_variables" {
  description = "Environment variables injected into the Lambda"
  type        = map(string)
  default     = {}
}

variable "project_tag" {
  description = "Value for the Project tag"
  type        = string
  default     = "ticket-classifier"
}
