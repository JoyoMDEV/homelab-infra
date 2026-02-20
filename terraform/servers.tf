resource "hcloud_ssh_key" "default" {
  name       = "homelab-key"
  public_key = file(var.ssh_public_key_path)
}

# Private Network between cloud servers
resource "hcloud_network" "k3s" {
  name     = "k3s-network"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "k3s" {
  network_id   = hcloud_network.k3s.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

resource "hcloud_firewall" "k3s" {
  name = "k3s-firewall"

  # SSH
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # k3s API
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Tailscale WireGuard
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTP/HTTPS (for later public phase)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

# CX53 - Control Plane (start here)
resource "hcloud_server" "k3s_server" {
  name        = "k3s-server"
  server_type = "cx53"
  image       = "ubuntu-24.04"
  location    = var.server_location
  ssh_keys    = [hcloud_ssh_key.default.id]

  firewall_ids = [hcloud_firewall.k3s.id]

  labels = {
    role    = "server"
    managed = "terraform"
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.k3s.id
    ip         = "10.0.1.1"
  }

  depends_on = [hcloud_network_subnet.k3s]
}

# CX43 - Cloud Worker (uncomment when ready)
# resource "hcloud_server" "k3s_worker_03" {
#   name        = "k3s-worker-03"
#   server_type = "cx43"
#   image       = "ubuntu-24.04"
#   location    = var.server_location
#   ssh_keys    = [hcloud_ssh_key.default.id]
#
#   firewall_ids = [hcloud_firewall.k3s.id]
#
#   labels = {
#     role    = "worker"
#     managed = "terraform"
#   }
#
#   public_net {
#     ipv4_enabled = true
#     ipv6_enabled = true
#   }
#
#   network {
#     network_id = hcloud_network.k3s.id
#     ip         = "10.0.1.2"
#   }
#
#   depends_on = [hcloud_network_subnet.k3s]
# }

# ─── Storage Box ──────────────────────────────────────────────────────────────
# bx21: 1 TB, dual-purpose:
#   /nextcloud/  → Nextcloud External Storage (Nutzerdateien via SFTP)
#   /backups/    → Restic (PVC Snapshots) + Velero (Cluster State)
#
# WICHTIG: ssh_keys können nach der Erstellung nicht per API geändert werden.
# Änderungen erzwingen Resource-Replacement (= Datenverlust!).
# Keys nur über Hetzner Cloud Console ändern.
# lifecycle.ignore_changes verhindert versehentlichen Replacement durch Terraform.

resource "hcloud_storage_box" "main" {
  name             = "homelab-storage"
  storage_box_type = "bx11"
  location         = var.storage_location
  password         = var.storage_box_password

  ssh_keys = [hcloud_ssh_key.default.public_key]

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
