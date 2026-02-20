variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "server_location" {
  description = "Hetzner datacenter location for Server"
  type        = string
  default     = "nbg1"
}

variable "storage_location" {
  description = "Hetzner datacenter location for Storage"
}

variable "storage_box_password" {
  description = "Password for the Hetzner Storage Box (set via TF_VAR_storage_box_password or terraform.tfvars)"
  type        = string
  sensitive   = true
}
