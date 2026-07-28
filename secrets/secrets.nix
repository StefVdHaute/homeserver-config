# agenix recipient rules. Read by the `agenix` CLI to decide which age
# public keys each encrypted file is readable by.
#
# Usage from repo root:
#   nix run github:ryantm/agenix -- -i ~/.ssh/id_ed25519 \
#     --rules secrets/secrets.nix -e secrets/<name>.age
#
# Both pubkeys live at /etc/nixos/* on the workstation (operator-managed,
# matching the same pattern as site.nix). `builtins.readFile` works here
# because the agenix CLI evaluates this file outside a pure flake context.
let
  strip = s: builtins.replaceStrings [ "\n" ] [ "" ] s;

  # Operator pubkey — same repo file (keys/operator.pub) baked into the
  # `operator` user's authorized_keys on both hosts.
  operator = strip (builtins.readFile ../keys/operator.pub);

  # main's SSH host pubkey. Pre-generated locally; the matching private
  # key gets shipped to /etc/ssh/ssh_host_ed25519_key on main at install
  # time via `nixos-anywhere --extra-files`. agenix on main decrypts using
  # that key.
  mainHost = strip (builtins.readFile /etc/nixos/main-host-key.pub);

  mainSecrets = [ operator mainHost ];
in {
  "restic.env.age".publicKeys = mainSecrets;
  "acme-credentials.env.age".publicKeys = mainSecrets;
  "main-root-sshkey.age".publicKeys = mainSecrets;
  "tailscale-authkey.age".publicKeys = mainSecrets;
}
