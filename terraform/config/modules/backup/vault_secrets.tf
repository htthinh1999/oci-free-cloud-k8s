# secrets have to name the key encrypting them; use the vault's (only) enabled AES master key
data "oci_kms_vault" "vault" {
  vault_id = var.vault_id
}

data "oci_kms_keys" "vault" {
  compartment_id      = var.compartment_id
  management_endpoint = data.oci_kms_vault.vault.management_endpoint
  algorithm           = "AES"

  filter {
    name   = "state"
    values = ["ENABLED"]
  }
}

# picked up by the ExternalSecrets in gitops/core/backup/secret.yaml
resource "oci_vault_secret" "access_key_id" {
  compartment_id = var.compartment_id
  vault_id       = var.vault_id
  key_id         = data.oci_kms_keys.vault.keys[0].id
  secret_name    = "k8s-backup-s3-access-key-id"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(oci_identity_customer_secret_key.k8s_backup.id)
  }
}

resource "oci_vault_secret" "secret_access_key" {
  compartment_id = var.compartment_id
  vault_id       = var.vault_id
  key_id         = data.oci_kms_keys.vault.keys[0].id
  secret_name    = "k8s-backup-s3-secret-access-key"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(oci_identity_customer_secret_key.k8s_backup.key)
  }
}
