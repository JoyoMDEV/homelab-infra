resource "hcloud_ssh_key" "default" {
  name       = "homelab-key"
  public_key = file(var.ssh_public_key_path)
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
  location    = var.location
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
}

# CX43 - Cloud Worker (uncomment when ready)
# resource "hcloud_server" "k3s_worker_03" {
#   name        = "k3s-worker-03"
#   server_type = "cx43"
#   image       = "ubuntu-24.04"
#   location    = var.location
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
# }
