# Role: tailscale

Installs and authenticates Tailscale on each host to form the Tailscale mesh VPN that connects cloud nodes and home nodes.

## What this role does

- Adds the official Tailscale apt repository and GPG key
- Installs the `tailscale` package
- Enables and starts `tailscaled`
- Authenticates the host with `tailscale up` using the provided auth key
- On the k3s server: disables `accept-dns` so Samba AD DNS is used instead
- On workers: accepts Tailscale DNS
- Opens the `tailscale0` interface in UFW
- Registers the Tailscale IP for use by subsequent roles (k3s, Samba)

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

- The server node runs with `--accept-dns=false` to prevent Tailscale from overriding the Samba AD DNS configuration
- Auth keys should be reusable and ephemeral — generate them in the Tailscale admin panel
