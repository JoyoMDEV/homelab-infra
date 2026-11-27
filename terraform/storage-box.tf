# The only Hetzner resource left (2026-11-27): the k3s-server, its network,
# firewall and SSH key were deleted when the cluster moved fully on-prem
# (context-hub#35). The Storage Box stays for now and is currently unused
# (no offsite backup yet, context-hub#36).

# WICHTIG: ssh_keys können nach der Erstellung nicht per API geändert werden.
# Änderungen erzwingen Resource-Replacement (= Datenverlust!).
# Keys nur über Hetzner Cloud Console ändern.
# lifecycle.ignore_changes verhindert versehentlichen Replacement durch Terraform.

resource "hcloud_storage_box" "main" {
  name             = "homelab-storage"
  storage_box_type = "bx11"
  location         = var.storage_location
  password         = var.storage_box_password

  # Was hcloud_ssh_key.default (deleted with the server). ssh_keys are in
  # ignore_changes anyway, so this only matters for a re-creation.
  ssh_keys = [file(pathexpand(var.ssh_public_key_path))]

  labels = {
    managed = "terraform"
    purpose = "nextcloud-and-backups"
  }

  access_settings = {
    reachable_externally = true # Nextcloud Pod + Restic brauchen externen Zugriff
    samba_enabled        = false
    ssh_enabled          = true # primär: Nextcloud External Storage + Restic/Velero
    webdav_enabled       = true # sekundär: manueller Zugriff / Debugging
    zfs_enabled          = true # kostenlose ZFS Point-in-Time Snapshots
  }

  snapshot_plan = {
    max_snapshots = 10 # ~10 Tage tägliche Snapshots
    minute        = 30
    hour          = 2 # 02:30 Uhr – nach dem Backup-Fenster
    day_of_week   = 0 # täglich
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ssh_keys]
  }
}
