locals {
  bucket_name = "${var.bucket_prefix}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "backup" {
  bucket = local.bucket_name

  tags = {
    Name    = local.bucket_name
    # S3 tag values reject parentheses -- allowed set is alphanumerics, spaces,
    # and + - = . _ : / @
    Purpose = "Offsite 3-2-1 backup target for the k8s-homelab cluster"
    Managed = "terraform-aws-backup"
  }
}

# Versioning is the guard against an accidental prune or a compromised
# backup credential deleting the repo. Retention is capped in the lifecycle
# rules below so this doesn't quietly double storage cost.
resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 rather than SSE-KMS on purpose: restic already encrypts every object
# client-side with its own key, so KMS would add per-request cost and a second
# key to manage for no additional confidentiality against AWS.
resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  # restic keeps its bulk content under data/. Everything else (config, keys/,
  # index/, snapshots/, locks/) is small and read on every single operation,
  # so it stays in STANDARD -- transitioning it would make each backup run
  # slower and more expensive, not less.
  rule {
    id     = "data-blobs-to-glacier-ir"
    status = "Enabled"

    filter {
      prefix = "data/"
    }

    transition {
      days          = var.glacier_ir_transition_days
      storage_class = "GLACIER_IR"
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }

  # Interrupted uploads of large blobs are billed until aborted and are
  # invisible in the console's object listing.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.backup]
}
