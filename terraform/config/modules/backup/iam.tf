# dedicated user whose S3 (customer secret) key can only touch the backup bucket
resource "oci_identity_group" "k8s_backup" {
  compartment_id = var.compartment_id
  description    = "K8sBackup"
  name           = "K8sBackup"
}

resource "oci_identity_user" "k8s_backup" {
  compartment_id = var.compartment_id
  description    = "K8sBackup"
  name           = "K8sBackup"
  email          = "htthinh1999@gmail.com"
}

resource "oci_identity_user_group_membership" "k8s_backup" {
  group_id = oci_identity_group.k8s_backup.id
  user_id  = oci_identity_user.k8s_backup.id
}

resource "oci_identity_user_capabilities_management" "k8s_backup" {
  user_id = oci_identity_user.k8s_backup.id

  can_use_customer_secret_keys = "true"
}

resource "oci_identity_customer_secret_key" "k8s_backup" {
  display_name = "k8s-backup"
  user_id      = oci_identity_user.k8s_backup.id

  depends_on = [oci_identity_user_capabilities_management.k8s_backup]
}

resource "oci_identity_policy" "k8s_backup" {
  compartment_id = var.compartment_id
  description    = "allow k8s backups to write to their bucket"
  name           = "K8sBackup"
  statements = [
    "Allow group 'Default'/'K8sBackup' to read buckets in tenancy where target.bucket.name='${var.bucket_name}'",
    "Allow group 'Default'/'K8sBackup' to manage objects in tenancy where target.bucket.name='${var.bucket_name}'"
  ]
}
