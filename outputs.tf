output "state_machine_arn" {
  description = "ARN of the Step Functions state machine"
  value       = aws_sfn_state_machine.ticket_pipeline.arn
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for classified tickets"
  value       = aws_s3_bucket.tickets.bucket
}
