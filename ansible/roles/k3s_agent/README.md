# Role: k3s_agent

Installs k3s as a worker node and joins it to the existing control plane over the Tailscale mesh VPN.

## What this role does

- Installs k3s via the official install script in agent mode
- Connects to the k3s server via Tailscale IP on port 6443
- Binds the agent to its own Tailscale IP (`--node-ip`, `--flannel-iface tailscale0`)
- Labels the node with `role=worker` and `location` (cloud or home)
- Waits until the node appears as Ready in the cluster

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `k3s_agent_version` | `""` | k3s version (empty = latest stable, should match server) |
| `k3s_agent_server_url` | `https://<tailscale-ip-of-server>:6443` | k3s API server URL |
| `k3s_agent_token` | `{{ vault_k3s_token }}` | Node join token (from Vault) |

## Vault variables required

```yaml
vault_k3s_token: "K10..."  # from /var/lib/rancher/k3s/server/node-token on the server
```

## Dependencies

- `common` — base packages and UFW
- `tailscale` — Tailscale IP must be available and the node must be reachable from the server
- `k3s_server` must have run on the server host before agents can join

## Usage

```yaml
- hosts: workers
  roles:
    - common
    - tailscale
    - k3s_agent
```

## Notes

- Home nodes (`location=home`) join via Tailscale — no public IP needed
- The `k3s_agent_server_url` is automatically derived from the server's Tailscale IP via `hostvars`
- Worker nodes are currently commented out in `inventory/hosts.yml` — uncomment to add them
