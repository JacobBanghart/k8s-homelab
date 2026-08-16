resource "aws_iam_user" "backup" {
  name = "k8s-homelab-backup"
  path = "/service/"

  tags = {
    Purpose = "restic offsite backup credential"
    Managed = "terraform-aws-backup"
  }
}

# Least privilege for a restic repository: list the bucket, and read/write/
# delete objects within it. No bucket-level administration, and no access to
# any other bucket in the account -- notably not to anything the Vault
# auto-unseal module owns.
data "aws_iam_policy_document" "backup" {
  statement {
    sid    = "ListBackupBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.backup.arn]
  }

  statement {
    sid    = "ReadWriteBackupObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.backup.arn}/*"]
  }
}

resource "aws_iam_user_policy" "backup" {
  name   = "k8s-homelab-backup-s3"
  user   = aws_iam_user.backup.name
  policy = data.aws_iam_policy_document.backup.json
}

resource "aws_iam_access_key" "backup" {
  user = aws_iam_user.backup.name
}
