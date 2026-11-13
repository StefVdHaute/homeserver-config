# homeserver-config

NixOS flake for three hosts: `main` (hostname `homeserver`, Dell R720),
`backup` (hostname `backupserver`, Raspberry Pi 4) and `workstation`
(Framework 16). `README.md` has the overview and the index of the other docs.

## Where things are

- `flake.nix`: the three `nixosConfigurations`. `main` and `backup` use
  `nixos-26.05`; `workstation` uses `nixos-unstable`.
- `modules/common.nix`: baseline for all hosts. `modules/alerts.nix`: the
  `ntfyNotify` helper, smartd and the failure notifiers, for `main` and `backup`.
- `hosts/<host>/`: one directory per host. The design rationale is in the
  comments at the top of each `.nix` file, not in the docs.
- `hosts/main/compose/`: one Compose file per service. Compose is started by
  hand on the host, not by NixOS.
- `secrets/`: agenix files; recipients in `secrets/secrets.nix`.

## Rules

- `/etc/nixos/site.nix` is a flake path input and must stay a real file. Never
  manage it with `environment.etc`: the flake then stops evaluating.
- The backup data drive must never appear in `hosts/backup/disko.nix`. No
  install may be able to format the restic repository.
- The restic password must never reach the Pi.
- Workstation Secure Boot uses the sbctl keys that Arch enrolled. Never set
  `autoGenerateKeys`, and never run `sbctl create-keys`, `setup` or
  `enroll-keys`.
- Pin every container image to an exact version and give it a
  `wud.tag.include` label.
- All Compose stacks share the project `compose`. Never run `down` or
  `--remove-orphans` on one stack.
- `hardware-configuration.nix` files are written by hand. Do not regenerate them.

## Checking a change

Evaluate each host you touched. No build is necessary:

    nix eval --raw .#nixosConfigurations.<main|backup|workstation>.config.system.build.toplevel.drvPath

A pure refactor must leave the derivation path unchanged.

## Docs

One topic per file: `DEPLOY.md` (first install), `RECOVERY.md` (loss and
rollback), `hosts/*/README.md` (day-to-day operation), `TODO.md` (open work).
Do not repeat in a doc what a `.nix` comment already says.
