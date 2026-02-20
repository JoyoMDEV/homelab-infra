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

# ─── Storage Box ──────────────────────────────────────────────────────────────

output "storage_box_host" {
  description = "SFTP Hostname der Storage Box (Format: uXXXXXX.your-storagebox.de)"
  value       = hcloud_storage_box.main.server
}

output "storage_box_username" {
  description = "SFTP Username der Storage Box"
  value       = hcloud_storage_box.main.username
}

output "storage_box_port" {
  description = "SFTP Port der Storage Box (Hetzner nutzt 23, nicht 22)"
  value       = 23
}

output "storage_box_webdav_url" {
  description = "WebDAV URL für manuellen Zugriff"
  value       = "https://${hcloud_storage_box.main.server}"
}

# Uncomment when CX43 worker is enabled
# output "k3s_worker_03_ip" {
#   description = "Public IPv4 of k3s-worker-03 (CX43)"
#   value       = hcloud_server.k3s_worker_03.ipv4_address
# }
#
# output "k3s_worker_03_private_ip" {
#   description = "Private IP of k3s-worker-03 in VLAN"
#   value       = "10.0.1.2"
# }
