# In the ci module, but not one of its admitted VMs: refused (#11).
resource "google_compute_instance_template" "builder" {
  name_prefix = "builder-"
}
