resource "aws_kms_key" "vault_unseal" {
  description             = "Auto-unseal key for the k8s-homelab Vault cluster"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/k8s-homelab-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}
