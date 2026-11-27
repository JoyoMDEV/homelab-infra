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

