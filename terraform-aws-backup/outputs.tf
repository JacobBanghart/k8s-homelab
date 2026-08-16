output "bucket_name" {
  description = "Name of the offsite backup bucket."
  value       = aws_s3_bucket.backup.id
}

output "bucket_arn" {
  description = "ARN of the offsite backup bucket."
  value       = aws_s3_bucket.backup.arn
}

output "aws_region" {
  value = var.aws_region
}

output "restic_repository" {
  description = "Value for RESTIC_REPOSITORY."
  value       = "s3:s3.${var.aws_region}.amazonaws.com/${aws_s3_bucket.backup.id}"
}

output "iam_access_key_id" {
  description = "Access key ID for the restic backup credential."
  value       = aws_iam_access_key.backup.id
}

output "iam_secret_access_key" {
  description = <<-EOT
    Secret access key for the restic backup credential. Never commit this --
    pull it once via `terraform output -raw iam_secret_access_key`, store it in
    Vault, and don't persist it anywhere else. This repo is PUBLIC.
  EOT
  value       = aws_iam_access_key.backup.secret
  sensitive   = true
}
