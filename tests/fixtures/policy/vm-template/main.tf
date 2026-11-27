# A looper VM's name outside the ci module, and a regional group: refused (#11).
resource "google_compute_instance_template" "looper_vm" {
  name_prefix = "looper-vm-"
}

resource "google_compute_region_instance_group_manager" "pool" {
  name = "pool"
}
