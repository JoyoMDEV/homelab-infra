# backup

Creates and manages daily Samba AD DC backups via `samba-tool domain backup online`
and uploads them to the Garage S3 bucket `samba-backup` with rclone.

## What it does

- Creates the local backup directory (`backup_dir`, default `/backup/samba`)
- Installs `rclone`
- Deploys `/usr/local/bin/samba-backup.sh` plus a systemd service and timer (daily 01:00)
- Triggers a first backup run

## What the backup script does (daily)

1. Runs `samba-tool dbcheck` and `samba-tool domain backup online` into `backup_dir/<timestamp>/`
2. `rclone copy` of `backup_dir` to the bucket (never `sync`, local cleanup must not delete remote backups)
3. Deletes remote files older than `backup_s3_retention_days` (default 30)
4. Removes local backups older than `backup_retention_days` (default 7)

## Variables

| Variable | Default | Description |
|---|---|---|
| `backup_dir` | `/backup/samba` | Local backup directory |
| `backup_retention_days` | `7` | Local retention |
| `backup_s3_endpoint` | `http://10.43.0.50:3900` | Fixed ClusterIP of `garage-s3-host` (`k8s/infrastructure/garage-s3-host-service.yaml`) |
| `backup_s3_region` | `garage` | Garage `s3_region` |
| `backup_s3_bucket` | `samba-backup` | Bucket |
| `backup_s3_access_key_id` | `{{ vault_garage_backup_access_key_id }}` | From Ansible Vault |
| `backup_s3_secret_access_key` | `{{ vault_garage_backup_secret_access_key }}` | From Ansible Vault |
| `backup_s3_retention_days` | `30` | Remote retention |
| `backup_timer_oncalendar` | `*-*-* 01:00:00` | systemd timer |

## Setup

```bash
./scripts/setup-garage-samba-backup.sh   # creates bucket + key in Garage
kubectl exec -n infrastructure garage-0 -c garage -- /garage key info samba-backup-key --show-secret
make vault-edit                          # add vault_garage_backup_access_key_id / ..._secret_access_key
make ansible-backup
```

The host reaches Garage through kube-proxy, so it must be a k3s node (server or agent).

## Limitations

Garage runs in the same cluster, so this is not an offsite backup. There is no alerting:
check `systemctl status samba-backup.service` and `journalctl -u samba-backup` now and then.

## Monitoring

```bash
systemctl list-timers samba-backup.timer
journalctl -u samba-backup.service -n 50
rclone ls GARAGE:samba-backup   # needs the RCLONE_CONFIG_GARAGE_* variables from the script
```
