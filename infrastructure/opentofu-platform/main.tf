provider "scaleway" {
  project_id = var.project_id
  region     = var.region
  zone       = var.zone
}

resource "scaleway_vpc" "main" {
  name = "autonomous-sre-vpc"
  tags = ["autonomous-sre", "managed-by-opentofu"]
}

resource "scaleway_vpc_private_network" "cluster" {
  name   = "autonomous-sre-cluster"
  vpc_id = scaleway_vpc.main.id
  tags   = ["autonomous-sre", "kubernetes"]

  ipv4_subnet {
    subnet = var.private_network_cidr
  }
}

resource "scaleway_instance_security_group" "cluster" {
  name                    = "autonomous-sre-cluster"
  description             = "K3s nodes. Public admin access is tightly scoped."
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # K3s, Cilium and node-to-node traffic remain on the private VPC.
  inbound_rule {
    action   = "accept"
    protocol = "ANY"
    ip_range = var.private_network_cidr
  }

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 22
    ip_range = var.operator_cidr
  }

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 22
    ip_range = var.runner_cidr
  }

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 6443
    ip_range = var.operator_cidr
  }

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 6443
    ip_range = var.runner_cidr
  }

  # HTTP is public only for ACME HTTP-01 challenges and HTTPS redirect.
  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 80
    ip_range = "0.0.0.0/0"
  }

  # The application HTTPS endpoint is restricted to the operator and the
  # self-hosted deployment runner. The runner needs HTTPS access so production
  # verification can exercise the real Gateway route after every deployment.
  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 443
    ip_range = var.operator_cidr
  }

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 443
    ip_range = var.runner_cidr
  }
}

resource "scaleway_instance_ip" "control_plane" {
  type = "routed_ipv4"
}

resource "scaleway_instance_server" "control_plane" {
  name              = "autonomous-sre-cp-01"
  type              = var.control_plane_type
  image             = "ubuntu_noble"
  ip_id             = scaleway_instance_ip.control_plane.id
  security_group_id = scaleway_instance_security_group.cluster.id
  tags              = ["autonomous-sre", "k3s-control-plane", "managed-by-opentofu"]

  root_volume {
    size_in_gb = 60
  }
}

resource "scaleway_instance_private_nic" "control_plane" {
  server_id          = scaleway_instance_server.control_plane.id
  private_network_id = scaleway_vpc_private_network.cluster.id
}

resource "scaleway_instance_ip" "worker" {
  count = var.worker_count
  type  = "routed_ipv4"
}

resource "scaleway_instance_server" "worker" {
  count             = var.worker_count
  name              = format("autonomous-sre-worker-%02d", count.index + 1)
  type              = var.worker_type
  image             = "ubuntu_noble"
  ip_id             = scaleway_instance_ip.worker[count.index].id
  security_group_id = scaleway_instance_security_group.cluster.id
  tags              = ["autonomous-sre", "k3s-worker", "managed-by-opentofu"]

  root_volume {
    size_in_gb = 80
  }
}

resource "scaleway_instance_private_nic" "worker" {
  count              = var.worker_count
  server_id          = scaleway_instance_server.worker[count.index].id
  private_network_id = scaleway_vpc_private_network.cluster.id
}
