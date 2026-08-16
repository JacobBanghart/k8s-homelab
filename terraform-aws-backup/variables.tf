variable "aws_region" {
  description = "AWS region for the offsite backup bucket."
  type        = string
  default     = "us-west-2"
}

variable "bucket_prefix" {
  description = <<-EOT
    Prefix for the backup bucket name. The AWS account ID is appended to make
    the name globally unique, so the final bucket is
    "<bucket_prefix>-<account_id>".
  EOT
  type        = string
  default     = "k8s-homelab-backup"
}

variable "glacier_ir_transition_days" {
  description = <<-EOT
    Days before restic's data/ blobs move to S3 Glacier Instant Retrieval.
    Glacier IR is ~3x cheaper than Standard-IA and still reads in
    milliseconds, so restic restores work without a separate thaw step.
    Note the 90-day minimum billable storage duration.
  EOT
  type        = number
  default     = 30
}

variable "noncurrent_version_retention_days" {
  description = <<-EOT
    Days to keep noncurrent object versions. Versioning exists to survive an
    accidental `restic forget --prune` or a bad delete, not as long-term
    history -- keep this short or it silently doubles the bill.
  EOT
  type        = number
  default     = 30
}
