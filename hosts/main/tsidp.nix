# tsidp: Tailscale's OIDC identity provider, so apps log in with your
# Tailscale identity. Runs as a NixOS service (nixpkgs module
# services.tsidp) and joins the tailnet itself through tsnet as
# idp.<tailnet>.ts.net, with its own Let's Encrypt cert. Not behind Caddy.
#
# Package from nixos-unstable: 26.05 ships 0.0.12, which misses five months
# of security updates and some login fixes. Upstream is experimental
# (pre-1.0), so every app keeps its local admin login as a fallback.
#
# Tailscale access policy needs: tag:tsidp in tagOwners, and a grant with
# app "tailscale.com/cap/tsidp" (allow_admin_ui, allow_dcr) for
# autogroup:member.
#
# State in /var/lib/private/tsidp (DynamicUser; /var/lib/tsidp is a
# symlink): the tsnet node identity (tailscaled.state), its cert, the OIDC
# signing key and the registered clients (oidc-funnel-clients.json).
# Backed up by the restic job tsidp-state. No auth key in the config: the
# registration key is single-use. If the state is lost and can't be
# restored, set services.tsidp.environmentFile once to a root-only file
# holding TS_AUTH_KEY=<new key with tag:tsidp>, and delete the old offline
# "idp" device in the admin console first so the name stays "idp".

{ pkgsUnstable, ... }:

{
  services.tsidp = {
    enable = true;
    package = pkgsUnstable.tsidp;
    settings.hostName = "idp";
  };
}
