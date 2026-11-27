# The ci module's looper VMs and reserved machines, admitted (#11); a VM read or removed is no VM made.
resource "google_compute_instance_template" "looper_vm" {
  name_prefix = "looper-vm-"
}

resource "google_compute_instance_group_manager" "looper_vm" {
  name = "looper-vm"
}

resource "google_compute_instance_template" "reserved_vm" {
  name_prefix = "reserved-vm-"
}

resource "google_compute_instance_group_manager" "reserved_vm" {
  name = "reserved-vm"
}

data "google_compute_instance" "read" {
  name = "read"
}

removed {
  from = google_compute_instance.manager
  lifecycle {
    destroy = true
  }
}
