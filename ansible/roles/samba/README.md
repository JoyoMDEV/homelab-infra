# Role: samba

Provisions a Samba Active Directory Domain Controller for `HOMELAB.LOCAL` with wildcard DNS resolution for `*.homelab.local` via Tailscale Split DNS.

## What this role does

- Installs Samba AD DC packages (`samba`, `winbind`, `krb5-user`, etc.)
- Provisions the domain `HOMELAB.LOCAL` if not already provisioned
- Configures the DNS forwarder (`1.1.1.1`)
- Allows simple LDAP bind (Tailscale provides transport encryption)
- Copies the Kerberos config to `/etc/krb5.conf`
- Disables `systemd-resolved` to avoid DNS conflicts
- Configures `/etc/resolv.conf` to use Samba's internal DNS
- Ensures the Tailscale IP is the only A record for the DC
- Adds a wildcard DNS record (`*`) pointing all `*.homelab.local` to the Tailscale IP
- Opens all required Samba ports in UFW

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `samba_realm` | `HOMELAB.LOCAL` | Kerberos realm / AD domain (FQDN) |
| `samba_domain` | `HOMELAB` | NetBIOS domain name |
| `samba_admin_password` | `{{ vault_samba_admin_password }}` | AD Administrator password (from Vault) |
| `samba_dns_forwarder` | `1.1.1.1` | Upstream DNS forwarder |

## Vault variables required

```yaml
vault_samba_admin_password: "..."
```

## Dependencies

- `common` — UFW must be configured
- `tailscale` — Tailscale IP is used as the DC's bind address and DNS record target

## Usage

```yaml
- hosts: server
  roles:
    - common
    - tailscale
    - k3s_server
    - samba
```

## Tailscale Split DNS

After the role runs, configure Tailscale Split DNS in the admin panel:

1. Admin Panel → DNS → Add nameserver
2. Enter the server's Tailscale IP
3. Restrict to domain: `homelab.local`

This routes all `*.homelab.local` queries from Tailscale devices to Samba.

## Notes

- The wildcard DNS record (`*`) means any new `*.homelab.local` service is automatically resolvable without changing DNS
- Samba runs as an AD DC on the host — not in Kubernetes — so Velero does not back it up. See the `backup` role for Samba-specific backups
- LDAP uses simple bind over Tailscale (no LDAPS needed — WireGuard encrypts the transport)
