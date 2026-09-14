provider "scaleway" {
  project_id = var.project_id
  region     = var.region
  zone       = var.zone
}

resource "scaleway_instance_security_group" "build" {
  name                    = "autonomous-sre-build-runners"
  description             = "Short-lived GitHub Actions build runner pool"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 22
    ip_range = var.manager_cidr
  }
}

resource "scaleway_instance_ip" "build" {
  count = var.runner_count
  type  = "routed_ipv4"
}

resource "scaleway_instance_server" "build" {
  count             = var.runner_count
  name              = format("%s-%02d", var.name_prefix, count.index + 1)
  type              = var.runner_type
  image             = "ubuntu_noble"
  ip_id             = scaleway_instance_ip.build[count.index].id
  security_group_id = scaleway_instance_security_group.build.id
  tags              = ["autonomous-sre", "github-build-runner", "ephemeral", "managed-by-opentofu"]

  root_volume {
    size_in_gb = 40
  }
}
