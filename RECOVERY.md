# Recovery

Every `secrets/*.age` file is encrypted to two keys: main's SSH host key and
the operator's key (`keys/operator.pub`). One of the two private keys is
enough to read them.

## Keep off-site

Keep at least one of these away from main and the workstation. Without it,
the loss of both machines makes the backups unreadable.

- The operator's `~/.ssh/id_ed25519` on an offline medium. Recovers everything.
- The plaintext `RESTIC_PASSWORD` in a password manager that main does not
  host. Recovers the backups only.

## Main is lost

1. Read the repository URL and password on any machine with the operator key:

       nix run github:ryantm/agenix -- -i ~/.ssh/id_ed25519 -d secrets/restic.env.age

2. Restore with `restic` from the Pi over SFTP.
3. For a new main: make a new host key, rekey (see below), and install again
   with `DEPLOY.md` section 6.

## The Pi is lost

If only the OS SSD died, flash it again (`DEPLOY.md` section 4) and attach the
data drive. No install step can format that drive.

If the data drive died, provision a new one (`DEPLOY.md` 5.1). The next 03:00
run on main creates a new repository. The snapshot history is gone; the
current data is still on main.

## Main's host key changed

Symptom: `/run/agenix/*` is missing and the services that need secrets fail.

    ssh operator@homeserver 'cat /etc/ssh/ssh_host_ed25519_key.pub' | sudo tee /etc/nixos/main-host-key.pub
    cd secrets && nix run github:ryantm/agenix -- -i ~/.ssh/id_ed25519 -r

Then push the rekeyed files and rebuild main.

## Rollback

- **NixOS:** `sudo nixos-rebuild switch --rollback`, or pick an older
  generation in the boot menu.
- **A bad change reached the auto-upgrade:** revert it in git and push. The
  next run repairs the hosts. The Pi skips its upgrade while main's ntfy is down.
- **A bad container image:** set the previous tag in the Compose file and run
  `up -d` for that stack.
- **Restic repository corruption:** `restic check` reports it. The Pi holds the
  only copy (`TODO.md`).

## Outside git

| File | On | Content | If lost |
|---|---|---|---|
| `/etc/nixos/site.nix` | workstation, main | Domain, ACME email, tailnet name. Must be identical on both: `flake.lock` pins its hash. | Write it again |
| `/etc/nixos/main-host-key{,.pub}` | workstation | Main's SSH host key pair; the public key is an agenix recipient | Rekey with the operator key |
| `~/.ssh/id_ed25519` | workstation | Operator key, the second agenix recipient | With main also gone: all secrets are lost |
| `hosts/main/.env` | main | Compose passwords and OIDC clients | Write it again from the password manager |
| `/etc/ntfy/url` | Pi | Base URL of main's ntfy | Write it again |
| `/etc/tailscale/authkey` | Pi | Tailscale auth key, used at first boot | Make a new key |
