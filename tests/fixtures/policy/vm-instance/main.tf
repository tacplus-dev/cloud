# A standalone VM, in any module: refused, with no exception (#11).
resource "google_compute_instance" "bastion" {
  name = "bastion"
}

resource "google_compute_instance_from_template" "one" {
  name = "one"
}
