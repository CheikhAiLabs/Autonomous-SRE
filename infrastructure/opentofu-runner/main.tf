provider "scaleway" {
  project_id = var.project_id
  region     = var.region
  zone       = var.zone
}

resource "scaleway_instance_ip" "runner" {
  type = "routed_ipv4"
}

resource "scaleway_instance_security_group" "runner" {
  name                    = "autonomous-sre-runner"
  description             = "Persistent GitHub Actions runner"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 22
    ip_range = var.operator_cidr
  }
}

resource "scaleway_instance_server" "runner" {
  name              = var.name
  type              = var.runner_type
  image             = "ubuntu_noble"
  ip_id             = scaleway_instance_ip.runner.id
  security_group_id = scaleway_instance_security_group.runner.id
  tags              = ["autonomous-sre", "github-runner", "managed-by-opentofu"]

  root_volume {
    size_in_gb = 30
  }
}
