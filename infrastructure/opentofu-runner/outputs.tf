output "runner_ip" {
  value = scaleway_instance_ip.runner.address
}

output "runner_id" {
  value = scaleway_instance_server.runner.id
}

output "runner_cidr" {
  value = "${scaleway_instance_ip.runner.address}/32"
}
