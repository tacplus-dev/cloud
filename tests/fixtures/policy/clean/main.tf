resource "google_storage_bucket_iam_member" "m" {
  bucket = "b"
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:a@p.iam.gserviceaccount.com"
}
