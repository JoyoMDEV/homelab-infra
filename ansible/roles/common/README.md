# Role: common

Base hardening and configuration applied to every host in the inventory.

## What this role does

- Updates apt cache and upgrades all packages
- Installs base packages (curl, git, vim, htop, ufw, fail2ban, etc.)
- Sets the timezone to `Europe/Berlin`
- Sets the hostname from `inventory_hostname`
- Hardens SSH (key-only auth, no root password login, max 3 auth tries)
- Configures UFW firewall (default deny incoming, allow SSH/6443/80/443)
- Allows GitLab SSH on port 2222 via Tailscale interface only
- Enables unattended-upgrades for automatic security patches
- Reboots the host if a kernel update requires it

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `timezone` | `Europe/Berlin` | System timezone |
| `ssh_port` | `22` | SSH port |

## Dependencies

None — this role runs first on every host.

## Usage

```yaml
- hosts: all
  roles:
    - common
```

## Tags

None defined — role always runs in full.
