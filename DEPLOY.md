# First install

Install the Pi first, then main: main's first upgrade waits for a backup to
the Pi. Workstation commands run from the repo root. On the servers the clone
is `~/server_config`.

## 1. Prerequisites

- **Main:** PERC H710P Mini flashed to IT mode, so Linux sees four plain disks.
- **Pi 4:** EEPROM bootloader 2020-10-28 or newer (GPT and USB boot). If it is
  older, boot the Raspberry Pi Imager "Bootloader > USB Boot" SD image once.
  Both USB bridges must pass SMART through (`-d sat`).
- **Workstation:** Nix with flakes, and aarch64 emulation for the Pi closure
  (`boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` on NixOS).
- **deSEC:** a subdomain (for example `home.dedyn.io`) and an API token.
- **Tailscale:** one reusable auth key, not ephemeral, not pre-approved. Keys
  expire after 90 days at most. For tsidp, the access policy needs the entries
  that `hosts/main/tsidp.nix` lists.

## 2. Keys and files outside git

```bash
# Per-site values. Must be identical on the workstation and on main.
sudo install -d -m 0755 /etc/nixos
sudo tee /etc/nixos/site.nix >/dev/null <<'EOF'
{
  acmeDomain = "home.dedyn.io";
  acmeEmail  = "you@example.com";
  tailnet    = "example-tailnet.ts.net";
}
EOF

# Main's SSH host key pair. The public key is an agenix recipient.
sudo ssh-keygen -t ed25519 -N "" -f /etc/nixos/main-host-key -C "main@homeserver"

# Operator public key: authorized on both servers, and an agenix recipient.
cp ~/.ssh/id_ed25519.pub keys/operator.pub

# Main's root key pair, for restic SFTP to the Pi.
ssh-keygen -t ed25519 -N "" -f /tmp/main-root-key -C "main-root@homeserver"
cp /tmp/main-root-key.pub keys/main-root.pub
```

Commit `keys/`. Encrypt `/tmp/main-root-key` in section 3, then delete it.

## 3. Secrets

```bash
cd secrets
AGENIX="nix run github:ryantm/agenix -- -i $HOME/.ssh/id_ed25519"
$AGENIX -e <name>.age        # opens $EDITOR
```

| File | Content |
|---|---|
| `restic.env.age` | `RESTIC_REPOSITORY=sftp:restic@backupserver.<tailnet>.ts.net:/mnt/backups/homeserver` and `RESTIC_PASSWORD=<openssl rand -hex 32>` |
| `acme-credentials.env.age` | `DESEC_TOKEN=<token>` |
| `main-root-sshkey.age` | The full content of `/tmp/main-root-key` |
| `tailscale-authkey.age` | The `tskey-auth-...` string |
| `operator-password.age` | Output of `mkpasswd -m sha-512`: the sudo password on main |
| `grafana-secret-key.age`, `grafana-admin-password.age` | A random string each |
| `portainer-admin-password.age` | The plaintext of the Portainer admin password |
| `grafana-oidc-secret.age`, `portainer-oidc-secret.age` | Client secrets from tsidp (section 6.7). Encrypt a placeholder until then. |

Save `RESTIC_PASSWORD` in a password manager that main does not host
(`RECOVERY.md` says why).

Then check that both servers evaluate:

```bash
nix flake lock
nix build --no-link --dry-run .#nixosConfigurations.main.config.system.build.toplevel
nix build --no-link --dry-run .#nixosConfigurations.backup.config.system.build.toplevel
```

## 4. Pi: flash the OS SSD on the workstation

Connect the SSD in its USB adapter to the workstation. Its by-id path must
match `device` in `hosts/backup/disko.nix`. The path includes the adapter, so
keep the same adapter on the Pi.

```bash
ls -l /dev/disk/by-id/ | grep usb

nix build .#nixosConfigurations.backup.config.system.build.toplevel -o /tmp/backup-toplevel
sudo nix run github:nix-community/disko -- --mode destroy,format,mount --flake .#backup
sudo nix shell nixpkgs#nixos-install-tools -c \
  nixos-install --system "$(readlink -f /tmp/backup-toplevel)" \
  --root /mnt --no-root-passwd --no-channel-copy

# sudo on the Pi needs a password; SSH is key-only.
sudo nix shell nixpkgs#nixos-install-tools -c nixos-enter --root /mnt -- passwd operator

# Files the Pi reads at run time.
sudo install -d -m 0755 /mnt/etc/tailscale /mnt/etc/ntfy
(cd secrets && $AGENIX -d tailscale-authkey.age) | sudo install -m 0600 /dev/stdin /mnt/etc/tailscale/authkey
echo "https://ntfy.<domain>" | sudo install -m 0600 /dev/stdin /mnt/etc/ntfy/url

sudo umount -R /mnt
```

## 5. Pi: first boot

1. Put both drives on the USB 3 ports, no SD card, and power on.
2. Approve `backupserver` in the Tailscale admin console.
3. `ssh operator@backupserver.<tailnet>.ts.net`

### 5.1 Data drive (new drive only)

On the Pi. This is the only step that formats the data drive:

```bash
git clone <repo-url> ~/server_config && cd ~/server_config/hosts/backup
ls -l /dev/disk/by-id/ | grep usb          # set device= in disko-data.nix
sudo nix run github:nix-community/disko -- --mode destroy,format,mount ./disko-data.nix
sudo install -d -m700 -o restic -g restic /mnt/backups/homeserver
```

### 5.2 SMART

```bash
for d in /dev/disk/by-id/usb-*0:0; do echo "== $d"; sudo smartctl -a -d sat "$d" | head -40; done
```

Both drives must show the "Vendor Specific SMART Attributes" table. An
enclosure that does not has no software fix: replace it. Add the data drive's
by-id path to `alerts.smartd.devices` in `hosts/backup/configuration.nix`.

## 6. Main

### 6.1 Disks

Boot any Linux with root SSH on main. Put the four by-id paths, in bay order,
into `diskIds` in `hosts/main/disko.nix`. disko wipes every disk in that list.

```bash
ls -l /dev/disk/by-id/ | grep -v part
```

### 6.2 Install

The host key must be on disk at first boot, or agenix cannot decrypt.
`site.nix` must be there for the auto-upgrade to evaluate the flake.

```bash
mkdir -p /tmp/main-extra/etc/ssh /tmp/main-extra/etc/nixos
sudo install -m 0600 /etc/nixos/main-host-key     /tmp/main-extra/etc/ssh/ssh_host_ed25519_key
sudo install -m 0644 /etc/nixos/main-host-key.pub /tmp/main-extra/etc/ssh/ssh_host_ed25519_key.pub
sudo install -m 0644 /etc/nixos/site.nix          /tmp/main-extra/etc/nixos/site.nix

nix run github:nix-community/nixos-anywhere -- \
  --flake .#main --target-host root@<main-lan-ip> --extra-files /tmp/main-extra

sudo rm -rf /tmp/main-extra
```

### 6.3 First login

Approve `homeserver` in the Tailscale admin console. Then:

```bash
ssh operator@homeserver.<tailnet>.ts.net
cat /proc/mdstat           # RAID 10 healthy
sudo ls /run/agenix/       # all secrets present
```

Add a wildcard A record at deSEC: subname `*`, value from `tailscale ip -4`.

### 6.4 Compose environment

```bash
git clone <repo-url> ~/server_config && cd ~/server_config/hosts/main
cp .env.example .env && vim .env       # the comments say how to make each value
```

### 6.5 Certificate

```bash
sudo journalctl -fu "acme-<domain>.service"     # wait for the certificate, 2-5 min
```

`caddy-reload-certs.service` fails until Caddy exists. The rebuild below
clears that.

### 6.6 Containers

```bash
# The firewall opens AdGuard and Grafana to Caddy on br-proxy only.
docker network create -o com.docker.network.bridge.name=br-proxy proxy

docker compose --env-file .env -f compose/caddy.yml up -d
sudo nixos-rebuild switch --flake ~/server_config#main

for svc in seafile vaultwarden joplin portainer ntfy wud homeassistant; do
  docker compose --env-file .env -f compose/$svc.yml up -d
done
```

### 6.7 Single sign-on

Register one client per app with tsidp. The callback URL of each app is in a
comment next to its OIDC settings:

```bash
curl -X POST https://idp.<tailnet>.ts.net/register \
  -d '{"client_name":"<app>","redirect_uris":["<callback>"]}'
```

The WUD, Vaultwarden and Seafile clients go into `.env`. The Grafana and
Portainer secrets go into their `.age` files; then rebuild main.

### 6.8 AdGuard

Complete the wizard at `https://adguard.<domain>` before 03:00, or the first
backup of its state is empty. Keep the defaults, create the admin user, and
pick the blocklists.

## 7. Smoke tests

```bash
# Each line must be 200, 302 or 401, not a TLS error.
for svc in home seafile vaultwarden joplin portainer wud ntfy homeassistant adguard grafana; do
  printf '%-14s ' "$svc"; curl -sSI "https://$svc.<domain>/" | head -1
done

docker logs joplin-init                   # "admin password rotated"

# First backups. The first one can take an hour.
for job in docker-volumes seafile-data adguard-state tsidp-state; do
  sudo systemctl start restic-backups-$job.service
done
ssh operator@backupserver.<tailnet>.ts.net ls /mnt/backups/homeserver/snapshots

sudo systemctl start tailscale-healthcheck.service     # on both hosts; must exit 0
sudo mdadm --monitor --scan --test --oneshot           # alert on home-smart
curl -d "test" http://127.0.0.1:8085/home-infra        # alert on home-infra
```

Subscribe the phone to the four topics first (`hosts/main/README.md`).

## 8. If a step fails

- **nixos-anywhere or the Pi flash stops partway:** run it again. Both are
  destructive and safe to repeat. Neither can touch the Pi's data drive.
- **A host does not appear on the tailnet:** it waits for approval, or the
  auth key expired. For the Pi, write a new key to `/etc/tailscale/authkey`
  and restart `tailscaled`.
- **`sudo` on main rejects the password:** see `hosts/main/README.md`.
- **USB resets in the Pi's `dmesg`:** two SSDs exceed the USB power budget.
  Use a powered hub for the data drive.
