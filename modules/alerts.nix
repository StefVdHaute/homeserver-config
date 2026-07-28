# Shared operator-alert plumbing: ntfy helper, smartd wiring, templated
# failure notifiers. Imported by each host config; driven by options under
# `alerts.*`. Keeps the per-host configuration.nix files free of duplicated
# systemd unit bodies and shell-script literals.
#
# Exposes `ntfyNotify` as a module arg so host configs can reuse it for
# their own inline hooks (restic backupCleanupCommand, etc.).

{ config, lib, pkgs, ... }:

let
  cfg = config.alerts;

  hasUrl     = cfg.ntfy.url     != null;
  hasUrlFile = cfg.ntfy.urlFile != null;

  # `ntfyNotify <topic> <priority> <title> <message>`
  # The URL source is resolved at run time, not at eval time — either a
  # literal Nix string (main: localhost) or a file read from disk (Pi:
  # operator-managed /etc/ntfy/url). `tr -d '\n'` strips the trailing
  # newline that `tee <<<` / heredocs / most editors add; otherwise the
  # composed URL would contain an embedded \n and curl would reject it.
  # writeShellApplication adds `set -euo pipefail` + shellcheck at build.
  ntfyNotifyPkg = pkgs.writeShellApplication {
    name = "ntfy-notify";
    runtimeInputs = [ pkgs.curl pkgs.coreutils ];
    text = ''
      topic="$1"; priority="$2"; title="$3"; message="$4"
      ${if hasUrl
        then ''base="${cfg.ntfy.url}"''
        else ''base="$(tr -d '\n' < ${toString cfg.ntfy.urlFile})"''
      }
      curl -fsS \
        --connect-timeout 5 --max-time 10 \
        -H "Priority: $priority" \
        -H "Title: $title" \
        -d "$message" \
        "$base/$topic" >/dev/null
    '';
  };
  # Keep `ntfyNotify` as a callable-path string so downstream callers
  # (${ntfyNotify} ...) don't care about the migration.
  ntfyNotify = "${ntfyNotifyPkg}/bin/ntfy-notify";
in

{
  options.alerts = {
    ntfy = {
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://127.0.0.1:8085";
        description = ''
          Base URL of the ntfy server as a Nix-time literal. Use this when
          the URL is stable and not site-dependent (e.g. a localhost port
          mapping). Mutually exclusive with `urlFile`.
        '';
      };
      urlFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/etc/ntfy/url";
        description = ''
          Path to a one-line file (operator-managed, outside Nix) holding
          the ntfy base URL. Use this when the URL is site-dependent (e.g.
          a tailnet hostname that shouldn't live in git). Mutually exclusive
          with `url`.
        '';
      };
    };

    smartd = {
      enable = lib.mkEnableOption "SMART monitoring with ntfy alerts";
      useDSat = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Pass `-d sat` to smartd. Required for most USB-SATA bridges so
          SMART commands are forwarded to the underlying SATA disk.
        '';
      };
      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/dev/disk/by-id/usb-Vendor_Model_Serial-0:0" ];
        description = ''
          Explicit devices to monitor (stable by-id paths recommended).
          When non-empty, DEVICESCAN is disabled. Required together with
          useDSat: `DEVICESCAN -d sat` scans zero devices, because sat is
          a pass-through protocol rather than a scannable device class.
        '';
      };
    };

    tailscaleHealthcheck = {
      enable = lib.mkEnableOption ''
        Active Tailscale connectivity healthcheck (complements the
        OnFailure hook on tailscaled.service, which only catches daemon
        crashes — this timer catches "daemon up but tailnet unreachable /
        not authed / rekey stuck").
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = (hasUrl || hasUrlFile) && !(hasUrl && hasUrlFile);
          message = "alerts.ntfy requires exactly one of `url` or `urlFile` to be set.";
        }
      ];

      # Expose the helper to host configs for inline use
      # (restic backupCleanupCommand, host-specific OnFailure units, …).
      _module.args.ntfyNotify = ntfyNotify;

      # Templated failure notifiers — always defined when the module loads.
      # Cheap to have idle; each host wires `OnFailure` → the one it needs.
      systemd.services."ntfy-backup-failure@" = {
        description = "Notify ntfy of failed backup unit %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${ntfyNotify} home-backup 3 'Backup FAILED' 'unit %i failed — run journalctl -u %i for details'";
        };
      };

      systemd.services."ntfy-infra-failure@" = {
        description = "Notify ntfy of failed infra unit %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${ntfyNotify} home-infra 4 'Host alert' 'unit %i failed on ${config.networking.hostName} — run journalctl -u %i for details'";
        };
      };
    }

    (lib.mkIf cfg.smartd.enable (
      let
        smartdNtfy = pkgs.writeShellApplication {
          name = "smartd-ntfy";
          text = ''
            exec ${ntfyNotify} home-smart 4 \
              "SMART alert: ${config.networking.hostName} — $SMARTD_DEVICE" \
              "$SMARTD_MESSAGE"
          '';
        };
      in {
        services.smartd = {
          enable = true;
          autodetect = cfg.smartd.devices == [ ];
          devices = map (d: { device = d; }) cfg.smartd.devices;
          defaults.monitored = "-a${lib.optionalString cfg.smartd.useDSat " -d sat"} -o on -s (S/../.././02|L/../../6/03) -M exec ${smartdNtfy}/bin/smartd-ntfy";
        };
      }
    ))

    (lib.mkIf cfg.tailscaleHealthcheck.enable (
      let
        tailscaleHealthcheck = pkgs.writeShellApplication {
          name = "tailscale-healthcheck";
          runtimeInputs = [ pkgs.tailscale pkgs.jq ];
          text = ''
            status=$(tailscale status --json)
            backend=$(echo "$status" | jq -r .BackendState)
            online=$(echo "$status" | jq -r .Self.Online)
            if [ "$backend" != "Running" ] || [ "$online" != "true" ]; then
              ${ntfyNotify} home-infra 4 \
                "Tailscale unhealthy on ${config.networking.hostName}" \
                "BackendState=$backend Self.Online=$online"
              exit 1
            fi
          '';
        };
      in {
      systemd.services.tailscale-healthcheck = {
        description = "Verify Tailscale connectivity (BackendState + Self.Online)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${tailscaleHealthcheck}/bin/tailscale-healthcheck";
        };
        # If the script itself errors out before reaching ntfyNotify (e.g.
        # `tailscale status --json` fails because the socket is unreachable
        # but the daemon process is still running), OnFailure catches it.
        unitConfig.OnFailure = [ "ntfy-infra-failure@tailscale-healthcheck.service" ];
      };
      systemd.timers.tailscale-healthcheck = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";           # let tailscale settle after boot
          OnUnitActiveSec = "15m";
          Persistent = false;
        };
      };
    }))
  ];
}
