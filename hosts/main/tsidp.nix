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
#
# Also here: portainer-oauth, which applies Portainer's tsidp login. Portainer
# keeps its auth settings in its own database, so a oneshot sets them through
# Portainer's API on every rebuild and daily (re-applies after a data reset).

{ config, lib, pkgs, pkgsUnstable, siteConfig, ... }:

let
  idp = "https://idp.${siteConfig.tailnet}";
  domain = siteConfig.acmeDomain;
  # Portainer's local admin is named after tsidp's email claim for the
  # operator, so "Login with OAuth" lands on that admin account.
  adminUser = "StefVdHaute@github.idp.${siteConfig.tailnet}";

  # Registered with tsidp's /register; the ID isn't secret.
  oauthSettings = {
    ClientID = "9f0d631c74e645df50e45f08218d4e63";
    AuthorizationURI = "${idp}/authorize";
    AccessTokenURI = "${idp}/token";
    ResourceURI = "${idp}/userinfo";
    RedirectURI = "https://portainer.${domain}";
    UserIdentifier = "email";
    # Space-separated: Portainer pastes this into the login URL unchanged,
    # and tsidp rejects a comma list with invalid_scope.
    Scopes = "openid email profile";
    OAuthAutoCreateUsers = false;
    SSO = false;
    LogoutURI = "";
    AuthStyle = 1;                 # client_secret_post, as registered
  };

  applyPortainerOauth = pkgs.writeShellApplication {
    name = "portainer-oauth";
    runtimeInputs = [ pkgs.curl pkgs.jq config.virtualisation.docker.package ];
    text = ''
      # Portainer only listens on the Docker proxy network.
      ip=""
      for _ in $(seq 1 24); do
        ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "proxy"}}{{.IPAddress}}{{end}}' portainer 2>/dev/null || true)
        if [ -n "$ip" ] && curl -sf -o /dev/null "http://$ip:9000/api/system/status"; then break; fi
        ip=""; sleep 5
      done
      if [ -z "$ip" ]; then
        echo "portainer not reachable; is the container running?" >&2
        exit 1
      fi
      api="http://$ip:9000/api"

      jwt=$(jq -n --arg u ${lib.escapeShellArg adminUser} \
              --rawfile p ${config.age.secrets.portainer-admin-password.path} \
              '{username: $u, password: $p}' \
            | curl -sf -X POST "$api/auth" -H 'Content-Type: application/json' --data @- \
            | jq -r .jwt)

      jq -n --argjson s ${lib.escapeShellArg (builtins.toJSON oauthSettings)} \
            --rawfile secret ${config.age.secrets.portainer-oidc-secret.path} \
            '{AuthenticationMethod: 3, OAuthSettings: ($s + {ClientSecret: $secret})}' \
        | curl -sf -X PUT "$api/settings" \
            -H "Authorization: Bearer $jwt" -H 'Content-Type: application/json' --data @- \
        | jq -c '{AuthenticationMethod, Scopes: .OAuthSettings.Scopes, RedirectURI: .OAuthSettings.RedirectURI}'
    '';
  };
in
{
  services.tsidp = {
    enable = true;
    package = pkgsUnstable.tsidp;
    settings.hostName = "idp";
  };

  age.secrets = {
    # Same password as PORTAINER_ADMIN_PASSWORD_HASH in .env (the plaintext).
    portainer-admin-password.file = ../../secrets/portainer-admin-password.age;
    # OIDC client secret from tsidp's dynamic client registration.
    portainer-oidc-secret.file = ../../secrets/portainer-oidc-secret.age;
  };

  systemd.services.portainer-oauth = {
    description = "Apply Portainer's tsidp OAuth login settings";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${applyPortainerOauth}/bin/portainer-oauth";
    };
    unitConfig.OnFailure = [ "ntfy-infra-failure@portainer-oauth.service" ];
  };
  systemd.timers.portainer-oauth = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };
}
