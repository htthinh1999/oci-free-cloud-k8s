data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_id
}

resource "oci_objectstorage_bucket" "backups" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = var.bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
}

# retention lives here rather than in the jobs, so they only ever need to upload
resource "oci_objectstorage_object_lifecycle_policy" "backups" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.backups.name

  rules {
    name        = "delete-after-${var.retention_days}-days"
    action      = "DELETE"
    is_enabled  = true
    target      = "objects"
    time_amount = var.retention_days
    time_unit   = "DAYS"
  }

  depends_on = [oci_identity_policy.objectstorage_lifecycle]
}

# object lifecycle rules are executed by the object storage service itself, which needs this grant
resource "oci_identity_policy" "objectstorage_lifecycle" {
  compartment_id = var.compartment_id
  description    = "allow object storage to run lifecycle rules"
  name           = "ObjectStorageLifecycle"
  statements = [
    "Allow service objectstorage-${var.region} to manage object-family in tenancy"
  ]
}
