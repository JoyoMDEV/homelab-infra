# Role: k3s_server

Installs and configures k3s as a single-node control plane. The cluster communicates exclusively over the Tailscale mesh VPN (flannel over `tailscale0`).

## What this role does

- Installs k3s via the official install script
- Binds k3s to the Tailscale IP (`--node-ip`, `--flannel-iface tailscale0`)
- Adds TLS SANs for both the Tailscale IP and the public IP
- Disables the built-in `servicelb` load balancer (Traefik handles ingress via hostPort)
- Labels the node with `role=server` and `location=cloud`
- Fetches the kubeconfig and rewrites the server address to the Tailscale IP
- Outputs the node join token for worker nodes

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `k3s_server_version` | `""` | k3s version to install (empty = latest stable) |
| `k3s_server_disable` | `[servicelb]` | k3s components to disable |

## Dependencies

- `common` — base packages and UFW
- `tailscale` — Tailscale IP must be available before k3s installation

## Usage

```yaml
- hosts: server
  roles:
    - common
    - tailscale
    - k3s_server
```

## Output

After the role runs, the kubeconfig is written to `kubeconfig` in the repo root with the Tailscale IP as the server address. Set `KUBECONFIG` or copy it to `~/.kube/config`.

## Notes

- k3s runs flannel over `tailscale0` — all pod-to-pod traffic is encrypted via WireGuard
- The kubeconfig server address is the Tailscale IP, so you must be connected to Tailscale to use kubectl
