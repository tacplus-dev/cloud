resource "google_storage_bucket_iam_member" "m" {
  bucket = "b"
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:a@p.iam.gserviceaccount.com"
}

resource "google_compute_global_address" "gateway" {
  name = "gateway"
  lifecycle {
    prevent_destroy = true
  }
}
