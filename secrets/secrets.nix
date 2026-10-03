# agenix recipient rules. Usage from repo root:
#   nix run github:ryantm/agenix -- -i ~/.ssh/id_ed25519 \
#     --rules secrets/secrets.nix -e secrets/<name>.age
let
  strip = s: builtins.replaceStrings [ "\n" ] [ "" ] s;

  operator = strip (builtins.readFile ../keys/operator.pub);

  # main's SSH host pubkey, read from the workstation (impure).
  mainHost = strip (builtins.readFile /etc/nixos/main-host-key.pub);

  mainSecrets = [ operator mainHost ];
in {
  "restic.env.age".publicKeys = mainSecrets;
  "acme-credentials.env.age".publicKeys = mainSecrets;
  "main-root-sshkey.age".publicKeys = mainSecrets;
  "tailscale-authkey.age".publicKeys = mainSecrets;
}
