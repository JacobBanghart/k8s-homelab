output "kms_key_id" {
  description = "KMS key ID for Vault's seal \"awskms\" stanza (kms_key_id)."
  value       = aws_kms_key.vault_unseal.key_id
}

output "aws_region" {
  value = var.aws_region
}

output "iam_access_key_id" {
  description = "Access key ID for the Vault runtime KMS credential."
  value       = aws_iam_access_key.vault_unseal.id
}

output "iam_secret_access_key" {
  description = "Secret access key for the Vault runtime KMS credential. Never commit this — pull it once via `terraform output -raw iam_secret_access_key` to create the Kubernetes Secret, then don't persist it elsewhere."
  value       = aws_iam_access_key.vault_unseal.secret
  sensitive   = true
}
