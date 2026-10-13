output "state_bucket" {
  description = "Name of the S3 bucket that holds this repo's Terraform state."
  value       = aws_s3_bucket.state.bucket
}
