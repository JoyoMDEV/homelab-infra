# Role: tailscale

Installs and authenticates Tailscale on each host to form the Tailscale mesh VPN that connects cloud nodes and home nodes.

## What this role does

- Adds the official Tailscale apt repository and GPG key
- Installs the `tailscale` package
- Enables and starts `tailscaled`
- Authenticates the host with `tailscale up` using the provided auth key
- On the k3s server: disables `accept-dns` (historical: was needed while the Samba AD DC served DNS there; the DC was removed in 2026-11)
- On workers: accepts Tailscale DNS
- Opens the `tailscale0` interface in UFW
- Registers the Tailscale IP for use by subsequent roles (k3s)

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `tailscale_auth_key` | `{{ vault_tailscale_auth_key }}` | Tailscale auth key (from Vault) |
| `tailscale_hostname_prefix` | `k3s` | Prefix for the Tailscale hostname |

## Vault variables required

```yaml
vault_tailscale_auth_key: "tskey-auth-..."
```

## Dependencies

- `common` must run first (UFW must be configured)

## Usage

```yaml
- hosts: all
  roles:
    - common
    - tailscale
```

## Notes

- The server node runs with `--accept-dns=false` (historical, see above)
- Auth keys should be reusable and ephemeral — generate them in the Tailscale admin panel
