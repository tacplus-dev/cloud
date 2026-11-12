# The runner manager replaced destroy-first, as before #46: the fleet would be left with no manager.
resource "google_compute_instance" "manager" {
  name = "runner-manager"
  tags = ["runner-manager"]
  lifecycle {
    replace_triggered_by = [terraform_data.config]
  }
}
