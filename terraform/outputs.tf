output "k3s_server_ip" {
  description = "Public IPv4 of k3s-server (CX53)"
  value       = hcloud_server.k3s_server.ipv4_address
}

output "k3s_server_private_ip" {
  description = "Private IP of k3s-server in VLAN"
  value       = "10.0.1.1"
}

output "k3s_server_ipv6" {
  description = "IPv6 of k3s-server"
  value       = hcloud_server.k3s_server.ipv6_address
}

output "ssh_command" {
  description = "SSH into the server"
  value       = "ssh root@${hcloud_server.k3s_server.ipv4_address}"
}

# Uncomment when CX43 is enabled
# output "k3s_worker_03_ip" {
#   description = "Public IPv4 of k3s-worker-03 (CX43)"
#   value       = hcloud_server.k3s_worker_03.ipv4_address
# }
#
# output "k3s_worker_03_private_ip" {
#   description = "Private IP of k3s-worker-03 in VLAN"
#   value       = "10.0.1.2"
# }
