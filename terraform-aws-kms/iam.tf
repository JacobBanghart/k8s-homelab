resource "aws_iam_user" "vault_unseal" {
  name = "k8s-homelab-vault-unseal"
}

resource "aws_iam_access_key" "vault_unseal" {
  user = aws_iam_user.vault_unseal.name
}

data "aws_iam_policy_document" "vault_unseal" {
  statement {
    sid    = "VaultKMSAutoUnseal"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.vault_unseal.arn]
  }
}

resource "aws_iam_user_policy" "vault_unseal" {
  name   = "vault-kms-auto-unseal"
  user   = aws_iam_user.vault_unseal.name
  policy = data.aws_iam_policy_document.vault_unseal.json
}
