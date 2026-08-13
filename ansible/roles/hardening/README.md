# SSH/k3s-API-Härtung — separates Runbook

**Warum getrennt vom normalen Provisioning:** Bei einem frischen Server
(`terraform apply` + erster `ansible-playbook`-Lauf) läuft Tailscale noch
nicht, wenn die `common`-Rolle greift. Würde SSH direkt auf `tailscale0`
beschränkt, sperrt sich Ansible mitten im ersten Lauf selbst aus — bevor
Tailscale überhaupt eingerichtet werden konnte. Deshalb: `common` lässt
SSH/6443 bootstrap-offen (`0.0.0.0/0`), **dieses** Runbook schränkt es
danach bewusst, separat und manuell ein.

## Voraussetzungen, VOR dem Ausführen prüfen

1. **Tailscale läuft bereits und ist authentifiziert** auf dem Ziel-Host:

   ```bash
   ssh <host-über-öffentliche-ip> "tailscale status"
   ```

   Muss den Host als "online" zeigen, nicht "Logged out" oder Ähnliches.

2. **`ansible_host` im Inventory auf die Tailscale-IP umstellen**, NICHT
   auf der öffentlichen IP lassen:

   ```yaml
   # ansible/inventory/hosts.yml
   k3s-server:
     ansible_host: 100.118.73.72 # Tailscale-IP, nicht die öffentliche!
   ```

   Das ist wichtig, weil Ansible selbst über diese Adresse verbindet — läuft
   der Playbook-Lauf noch über die öffentliche IP, während UFW die Regel
   gerade umschreibt, kann es zu einem kurzen Verbindungsabbruch kommen,
   bevor die neue (Tailscale-)Regel greift.

3. **Eine zweite, unabhängige SSH-Session offen halten**, während du das
   Playbook laufen lässt — als Rettungsleine, falls doch etwas schiefgeht:
   ```bash
   ssh <host-über-tailscale-ip>   # in einem zweiten Terminal offen lassen
   ```

## Ausführen

```bash
cd ansible
ansible-playbook playbooks/harden-ssh.yml
```

## Danach verifizieren

```bash
# Auf dem Host selbst:
sudo ufw status verbose
# Sollte "22/tcp on tailscale0" und "6443/tcp on tailscale0" zeigen,
# NICHT mehr "22/tcp ... Anywhere"

# Von außerhalb, OHNE Tailscale (z.B. Handy-Hotspot):
nc -zv -w3 <öffentliche-ip> 22
nc -zv -w3 <öffentliche-ip> 6443
# Sollte jetzt Timeout/Connection refused zeigen
```

## Falls doch etwas schiefgeht

Über die zweite offene SSH-Session (falls die noch verbunden ist):

```bash
sudo ufw allow 22/tcp
sudo ufw allow 6443/tcp
```

Stellt den bootstrap-offenen Zustand wieder her, bis das Problem geklärt ist.

Falls auch die zweite Session weg ist: Hetzner Cloud Console (Rescue-System /
VNC-Konsole im Hetzner-Dashboard) nutzen, um lokal auf den Server zuzugreifen
und `ufw` zurückzusetzen.
