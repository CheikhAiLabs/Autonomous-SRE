output "runner_ips" {
  value = [for ip in scaleway_instance_ip.build : ip.address]
}

output "runner_ids" {
  value = [for server in scaleway_instance_server.build : server.id]
}

output "runner_names" {
  value = [for server in scaleway_instance_server.build : server.name]
}
