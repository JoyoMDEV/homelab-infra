# Role: backup

Creates and manages daily Samba AD DC backups via `samba-tool domain backup online` and syncs them to the Hetzner Storage Box via rsync over SSH.

## What this role does

- Creates the local backup directory (`/backup/samba`)
- Generates an SSH key pair for rsync authentication (`/root/.ssh/id_ed25519_backup`)
- Displays the public key and pauses for manual registration on the Storage Box
- Adds the Storage Box SSH fingerprint to `known_hosts`
- Creates the remote backup directory on the Storage Box
- Deploys the backup script to `/usr/local/bin/samba-backup.sh`
- Deploys a systemd service and timer (daily at 01:00)
- Triggers the first backup immediately after setup

## Backup script behaviour

Each run of `samba-backup.sh`:

1. Runs `samba-tool dbcheck` to verify DB integrity before backup
2. Creates a timestamped backup via `samba-tool domain backup online --include-secrets`
3. Rsyncs the entire backup directory to the Storage Box
4. Removes remote backups older than `backup_storage_box_retention_days` (default: 30 days)
5. Removes local backups older than `backup_retention_days` (default: 7 days)

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `backup_dir` | `/backup/samba` | Local backup directory on the host |
| `backup_retention_days` | `7` | Days to keep local backups |
| `backup_storage_box_host` | `{{ vault_storage_box_host }}` | Storage Box hostname (from Vault) |
| `backup_storage_box_user` | `{{ vault_storage_box_user }}` | Storage Box username (from Vault) |
| `backup_storage_box_port` | `23` | Storage Box SFTP/SSH port |
| `backup_storage_box_remote_path` | `/samba-backup` | Remote directory on the Storage Box |
| `backup_storage_box_retention_days` | `30` | Days to keep remote backups |
| `backup_ssh_key_path` | `/root/.ssh/id_ed25519_backup` | Path to the SSH private key |
| `backup_timer_oncalendar` | `*-*-* 01:00:00` | systemd timer schedule |

## Vault variables required

```yaml
vault_samba_admin_password: "..."   # used by samba-tool to authenticate
vault_storage_box_host: "u123456.your-storagebox.de"
vault_storage_box_user: "u123456"
```

## Dependencies

- `common` — base packages
- `tailscale` — host must be reachable
- `samba` — Samba AD DC must be provisioned and running

## Usage

```yaml
- hosts: server
  roles:
    - common
    - tailscale
    - k3s_server
    - samba
    - backup
```

## First run

On the first run the role will pause and display the generated SSH public key:

```
============================================================
SSH Public Key für Storage Box – bitte manuell hinterlegen:
ssh-ed25519 AAAA... samba-backup@k3s-server
============================================================
```

Register this key on the Storage Box (Hetzner Console → Storage Box → SSH Keys), then press Enter to continue.

## Monitoring

```bash
# Timer status and recent logs
make samba-backup-status

# Manual backup trigger
ssh root@<server-ip> /usr/local/bin/samba-backup.sh

# Check systemd journal
journalctl -u samba-backup --since "24h ago"
```

## Recovery

See `docs/backup-strategy.md` — Szenario C for the full recovery procedure.

In short:
```bash
# On a new server after fresh Samba provision:
samba-tool domain backup restore \
  --backup-file=/path/to/samba-backup-HOMELAB.LOCAL-<timestamp>.tar.bz2 \
  --newservername=k3s-server \
  --targetdir=/var/lib/samba-restored
```
