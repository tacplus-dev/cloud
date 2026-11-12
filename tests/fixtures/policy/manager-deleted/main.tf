# The runner manager replaced create-before-destroy, as #46 made it: the apply deletes the old one, and the jobs it
# is running with it (#48).
resource "google_compute_instance" "manager" {
  name = "runner-manager-0a1b2c3d"
  tags = ["runner-manager"]
  lifecycle {
    create_before_destroy = true
  }
}
