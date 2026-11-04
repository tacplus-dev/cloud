# A public address that an apply could destroy: its IP would be lost with it.
resource "google_compute_global_address" "gateway" {
  name         = "gateway"
  address_type = "EXTERNAL"
}

resource "google_compute_global_address" "kept" {
  name = "kept"
  lifecycle {
    prevent_destroy = true
  }
}
