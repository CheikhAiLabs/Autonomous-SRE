output "control_plane_public_ip" {
  value = scaleway_instance_ip.control_plane.address
}

output "control_plane_private_ip" {
  value = scaleway_instance_private_nic.control_plane.private_ips[0].address
}

output "control_plane_id" {
  value = scaleway_instance_server.control_plane.id
}

output "control_plane_fqdn" {
  value = "${element(reverse(split("/", scaleway_instance_server.control_plane.id)), 0)}.pub.instances.scw.cloud"
}

output "worker_public_ips" {
  value = [for ip in scaleway_instance_ip.worker : ip.address]
}

output "worker_private_ips" {
  value = [for nic in scaleway_instance_private_nic.worker : nic.private_ips[0].address]
}

output "worker_ids" {
  value = [for node in scaleway_instance_server.worker : node.id]
}

output "private_network_id" {
  value = scaleway_vpc_private_network.cluster.id
}
