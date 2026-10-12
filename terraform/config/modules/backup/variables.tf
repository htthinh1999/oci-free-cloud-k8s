variable "compartment_id" {
  type        = string
  description = "The compartment to create the resources in"
}

variable "region" {
  type        = string
  description = "OCI region the bucket and vault live in"
}

variable "vault_id" {
  type        = string
  description = "The OCID of the Vault to store the S3 credentials in"
}

variable "vault_key_id" {
  type        = string
  description = "The OCID of the Vault master encryption key used for the secrets"
}

variable "bucket_name" {
  type        = string
  description = "Bucket the in-cluster backup CronJobs (gitops/core/backup) upload to"
  default     = "k8s-backups"
}

variable "retention_days" {
  type        = number
  description = "Backups older than this are deleted by an object lifecycle rule"
  default     = 14
}
