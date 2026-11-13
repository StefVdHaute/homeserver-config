# In-band view of what the iDRAC reports, tailnet-only behind Caddy:
#
#   grafana.DOMAIN  Grafana: "Server health (R720)" (iDRAC summary, sensors,
#                   PSUs, power, event log, SMART, RAID, ECC) plus the
#                   community "Node Exporter Full" dashboard.
#
# Prometheus scrapes node_exporter, ipmi_exporter (local BMC via /dev/ipmi0)
# and smartctl_exporter; its alerts go Alertmanager -> alertmanager-ntfy ->
# the local ntfy (home-infra / home-smart).
#
# OS tasks (journal, services, storage, reboot) go over SSH. No Cockpit:
# it duplicated SSH and Grafana, added a password login on the web, and its
# service/storage/network/user changes drift from the NixOS config.
#
# What stays iDRAC-only: power-on and the console while the OS is down, BIOS
# setup and virtual media. Keep the iDRAC on the LAN for those.
#
# Ports (all on the host): AdGuard 3000, Grafana 3001, Prometheus 9092,
# Alertmanager 9093, node 9100, ipmi 9290, smartctl 9633, alertmanager-ntfy
# 8000. Caddy (container on the `proxy` network) reaches Grafana and
# AdGuard via host.docker.internal; the firewall only
# opens those ports on the proxy bridge (`br-proxy`, see DEPLOY.md 6.6) and on
# the trusted tailscale0.

{ config, lib, pkgs, siteConfig, ... }:

let
  domain = siteConfig.acmeDomain;

  # tsidp (./tsidp.nix) on the tailnet; the tailnet name comes from site.nix.
  idp = "https://idp.${siteConfig.tailnet}";
  # tsidp rewrites GitHub logins in the email claim to
  # <user>@github.<idp host> (realishEmail), so match that form.
  grafanaAdminEmail = "StefVdHaute@github.idp.${siteConfig.tailnet}";

  ports = {
    adguard = config.services.adguardhome.port;
    grafana = 3001;
    prometheus = 9092;
    alertmanager = 9093;
    alertmanagerNtfy = 8000;
  };

  exporters = config.services.prometheus.exporters;

  # The four disks from ./disko.nix, by-id (labels carry the serial).
  diskDevices = lib.mapAttrsToList (_: d: d.device) config.disko.devices.disk;

  # ---------------------------------------------------------------- IPMI
  # freeipmi needs uid 0 for the in-band driver (/dev/ipmi0) and a writable
  # SDR cache; ProtectHome hides /root, so point the cache at CacheDirectory.
  ipmiCache = "/var/cache/prometheus-ipmi-exporter";
  sdrCacheArgs = [ "--sdr-cache-directory" ipmiCache ];

  ipmiExporterConfig = (pkgs.formats.yaml { }).generate "ipmi_local.yml" {
    modules.default = {
      collectors = [ "bmc" "ipmi" "dcmi" "chassis" "sel" "sel-events" ];
      custom_args = {
        ipmi = sdrCacheArgs;
        sel = sdrCacheArgs;
        sel-events = sdrCacheArgs;
      };
      # Counted from the BMC's System Event Log (ipmi-sel event text).
      # DIMM_B2 logged multi-bit errors in 2025; these make new ones visible.
      sel_events = [
        { name = "memory_correctable"; regex = ''(?i)\bcorrectable (ECC|memory)''; }
        { name = "memory_uncorrectable"; regex = ''(?i)(uncorrectable (ECC|memory)|multi.?bit)''; }
        { name = "power_supply"; regex = ''(?i)(power supply|PSU|redundancy)''; }
      ];
    };
  };

  # -------------------------------------------------------------- alerts
  # Every rule sets `topic`, which alertmanager-ntfy uses as the ntfy topic.
  sensorStates = ''{__name__=~"ipmi_(temperature|fan_speed|voltage|current|power|sensor)_state"}'';

  alertRules = [
    {
      alert = "IpmiSensorCritical";
      expr = "${sensorStates} == 2";
      for = "2m";
      labels = { severity = "critical"; topic = "home-infra"; };
      annotations.summary = "BMC sensor {{ $labels.name }} is critical on homeserver";
    }
    {
      alert = "IpmiSensorWarning";
      expr = "${sensorStates} == 1";
      for = "10m";
      labels = { severity = "warning"; topic = "home-infra"; };
      annotations.summary = "BMC sensor {{ $labels.name }} is in warning on homeserver";
    }
    {
      alert = "IpmiUnreachable";
      expr = "ipmi_up == 0";
      for = "15m";
      labels = { severity = "warning"; topic = "home-infra"; };
      annotations.summary = "IPMI collector {{ $labels.collector }} failing on homeserver (BMC unreachable from the OS?)";
    }
    {
      alert = "MemoryUncorrectableErrors";
      expr = "increase(node_edac_uncorrectable_errors_total[1h]) > 0";
      labels = { severity = "critical"; topic = "home-infra"; };
      annotations.summary = "Uncorrectable ECC memory errors on homeserver (controller {{ $labels.controller }}); replace the DIMM";
    }
    {
      alert = "MemoryCorrectableErrorsHigh";
      expr = "increase(node_edac_correctable_errors_total[24h]) > 10";
      labels = { severity = "warning"; topic = "home-infra"; };
      annotations.summary = "{{ $value }} correctable ECC errors in 24h on homeserver (controller {{ $labels.controller }})";
    }
    {
      alert = "DiskHot";
      expr = ''smartctl_device_temperature{temperature_type="current"} > 50'';
      for = "15m";
      labels = { severity = "warning"; topic = "home-smart"; };
      annotations.summary = "Disk {{ $labels.device }} at {{ $value }}°C on homeserver";
    }
    {
      alert = "BtrfsDeviceErrors";
      expr = "increase(node_btrfs_device_errors_total[1h]) > 0";
      labels = { severity = "warning"; topic = "home-smart"; };
      annotations.summary = "btrfs {{ $labels.type }} errors on {{ $labels.device }} (homeserver); scrub /mnt/data to repair";
    }
    {
      alert = "FilesystemAlmostFull";
      expr = ''node_filesystem_avail_bytes{mountpoint=~"/|/mnt/data"} / node_filesystem_size_bytes{mountpoint=~"/|/mnt/data"} < 0.10'';
      for = "15m";
      labels = { severity = "warning"; topic = "home-infra"; };
      annotations.summary = "{{ $labels.mountpoint }} on homeserver has less than 10% free";
    }
    {
      alert = "LowMemory";
      expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.05";
      for = "10m";
      labels = { severity = "warning"; topic = "home-infra"; };
      annotations.summary = "homeserver has less than 5% memory available";
    }
    {
      # restic and the ntfy notifiers already alert on their own failures.
      alert = "SystemdUnitFailed";
      expr = ''node_systemd_unit_state{state="failed",name!~"(restic-|ntfy-).*"} == 1'';
      for = "5m";
      labels = { severity = "warning"; topic = "home-infra"; };
      annotations.summary = "Unit {{ $labels.name }} failed on homeserver";
    }
    {
      alert = "ScrapeTargetDown";
      expr = "up == 0";
      for = "10m";
      labels = { severity = "warning"; topic = "home-infra"; };
      annotations.summary = "Monitoring target {{ $labels.job }} is down on homeserver";
    }
  ];

  # ---------------------------------------------------------- dashboards
  serverHealthJson = pkgs.writeText "server-health.json"
    (builtins.toJSON (import ./dashboards/server-health.nix { inherit lib; }));

  # https://grafana.com/grafana/dashboards/1860 (Node Exporter Full)
  nodeExporterFullJson = pkgs.fetchurl {
    url = "https://grafana.com/api/dashboards/1860/revisions/46/download";
    name = "node-exporter-full-46.json";
    hash = "sha256-5Y3cXcU11MkB+U2pZIvD49Wue2946Y4YW86LKJlhzqM=";
  };

  # Real files, not symlinks, for Grafana's file provisioner.
  dashboards = pkgs.runCommand "grafana-dashboards" { } ''
    mkdir $out
    cp ${serverHealthJson} $out/server-health.json
    cp ${nodeExporterFullJson} $out/node-exporter-full.json
  '';
in
{
  # ============================================================
  # Secrets
  # ============================================================
  age.secrets = {
    grafana-secret-key = { file = ../../secrets/grafana-secret-key.age; owner = "grafana"; };
    grafana-admin-password = { file = ../../secrets/grafana-admin-password.age; owner = "grafana"; };
    # OIDC client secret from tsidp's dynamic client registration.
    grafana-oidc-secret = { file = ../../secrets/grafana-oidc-secret.age; owner = "grafana"; };
  };

  # ============================================================
  # Exporters (localhost only; Prometheus is the only reader)
  # ============================================================
  services.prometheus.exporters = {
    node = {
      enable = true;
      listenAddress = "127.0.0.1";
      # mdadm, edac, btrfs and hwmon are on by default.
      enabledCollectors = [ "systemd" ];
    };

    smartctl = {
      enable = true;
      listenAddress = "127.0.0.1";
      devices = diskDevices;
      maxInterval = "5m";
    };

    ipmi = {
      enable = true;
      listenAddress = "127.0.0.1";
      configFile = ipmiExporterConfig;
    };
  };

  systemd.services.prometheus-ipmi-exporter.serviceConfig = {
    # freeipmi's in-band driver refuses to run unless uid is 0.
    DynamicUser = lib.mkForce false;
    User = lib.mkForce "root";
    Group = lib.mkForce "root";
    PrivateDevices = lib.mkForce false;
    DeviceAllow = lib.mkForce [ "/dev/ipmi0 rw" ];
    CacheDirectory = "prometheus-ipmi-exporter";
  };

  # Copies new BMC event-log entries into the journal, so they show up in
  # `journalctl -u ipmiseld` (iDRAC: Logs > SEL).
  systemd.services.ipmiseld = {
    description = "Log IPMI System Event Log entries to the journal";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.freeipmi}/bin/ipmiseld --foreground --cache-directory=/var/cache/ipmiseld --poll-interval=300";
      CacheDirectory = "ipmiseld";
      Restart = "on-failure";
      RestartSec = "1min";
    };
  };

  # ============================================================
  # Prometheus + Alertmanager -> ntfy
  # ============================================================
  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = ports.prometheus;          # not the 9090 default; kept from when Cockpit had it
    retentionTime = "90d";
    globalConfig = {
      scrape_interval = "30s";
      evaluation_interval = "30s";
    };

    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [ { targets = [ "127.0.0.1:${toString exporters.node.port}" ]; } ];
      }
      {
        # freeipmi calls are slow; one scrape a minute is plenty.
        job_name = "ipmi";
        scrape_interval = "1m";
        scrape_timeout = "50s";
        static_configs = [ { targets = [ "127.0.0.1:${toString exporters.ipmi.port}" ]; } ];
      }
      {
        job_name = "smartctl";
        scrape_interval = "2m";
        scrape_timeout = "1m";
        static_configs = [ { targets = [ "127.0.0.1:${toString exporters.smartctl.port}" ]; } ];
      }
      {
        job_name = "prometheus";
        static_configs = [ { targets = [ "127.0.0.1:${toString ports.prometheus}" ]; } ];
      }
      {
        job_name = "alertmanager";
        static_configs = [ { targets = [ "127.0.0.1:${toString ports.alertmanager}" ]; } ];
      }
    ];

    rules = [ (builtins.toJSON { groups = [ { name = "homeserver"; rules = alertRules; } ]; }) ];

    alertmanagers = [ { static_configs = [ { targets = [ "127.0.0.1:${toString ports.alertmanager}" ]; } ]; } ];

    alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.alertmanager;
      # Single node: don't open the gossip port (9094 on all interfaces).
      extraFlags = [ "--cluster.listen-address=" ];
      configuration = {
        route = {
          receiver = "ntfy";
          group_by = [ "alertname" "topic" ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";
        };
        receivers = [ {
          name = "ntfy";
          webhook_configs = [ { url = "http://127.0.0.1:${toString ports.alertmanagerNtfy}/hook"; } ];
        } ];
      };
    };

    alertmanager-ntfy = {
      enable = true;
      settings = {
        http.addr = "127.0.0.1:${toString ports.alertmanagerNtfy}";
        ntfy = {
          baseurl = config.alerts.ntfy.url;
          notification = {
            # gval expression: the rule's `topic` label.
            topic = "labels.topic";
            priority = ''labels.severity == "critical" ? "urgent" : (status == "firing" ? "high" : "default")'';
          };
        };
      };
    };
  };

  # ============================================================
  # Grafana (grafana.DOMAIN)
  # ============================================================
  services.grafana = {
    enable = true;
    settings = {
      server = {
        # 0.0.0.0 so Caddy (Docker) can reach it; the firewall below limits
        # it to the proxy bridge and tailscale0.
        http_addr = "0.0.0.0";
        http_port = ports.grafana;
        inherit domain;
        root_url = "https://grafana.${domain}/";
      };
      security = {
        secret_key = "$__file{${config.age.secrets.grafana-secret-key.path}}";
        # The local admin is the same account as the tsidp login (matched by
        # email, see auth.oauth_allow_insecure_email_lookup). Only applied
        # when Grafana creates its database.
        admin_user = "stefvdhaute";
        admin_email = grafanaAdminEmail;
        admin_password = "$__file{${config.age.secrets.grafana-admin-password.path}}";
        cookie_secure = true;
        disable_gravatar = true;
      };
      users.allow_sign_up = false;

      # Link a tsidp login to the existing user with the same email (the
      # local admin). Safe here: tsidp derives the email from the Tailscale
      # login and only tailnet members can reach it.
      auth.oauth_allow_insecure_email_lookup = true;

      # "Sign in with Tailscale" via tsidp. The local admin login stays
      # available as a fallback (no auto_login, login form kept).
      "auth.generic_oauth" = {
        enabled = true;
        name = "Tailscale";
        # Creates the Grafana user on first OIDC login (the sign-up form
        # stays off). Only autogroup:member can reach tsidp.
        allow_sign_up = true;
        # Registered with tsidp's /register; the ID isn't secret.
        client_id = "86556cec5789edfcd1466130398317d1";
        client_secret = "$__file{${config.age.secrets.grafana-oidc-secret.path}}";
        scopes = "openid email profile";
        auth_url = "${idp}/authorize";
        token_url = "${idp}/token";
        api_url = "${idp}/userinfo";
        auth_style = "InHeader";        # registered as client_secret_basic
        use_pkce = true;
        email_attribute_path = "email";
        login_attribute_path = "username";
        name_attribute_path = "name";
        role_attribute_path = "email == '${grafanaAdminEmail}' && 'Admin' || 'Viewer'";
      };

      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        check_for_plugin_updates = false;
      };
      dashboards.default_home_dashboard_path = "${dashboards}/server-health.json";
    };

    provision = {
      enable = true;
      datasources.settings.datasources = [ {
        name = "Prometheus";
        uid = "prometheus";
        type = "prometheus";
        url = "http://127.0.0.1:${toString ports.prometheus}";
        isDefault = true;
        jsonData.timeInterval = "30s";
      } ];
      dashboards.settings.providers = [ {
        name = "homeserver";
        options.path = dashboards;
        disableDeletion = true;
        allowUiUpdates = false;
      } ];
    };
  };

  # ============================================================
  # Firewall: Caddy -> host services
  # ============================================================
  # The `proxy` Docker network uses the fixed bridge name br-proxy
  # (DEPLOY.md 6.6). Packets from Caddy to host.docker.internal enter there.
  networking.firewall.interfaces.br-proxy.allowedTCPPorts = [
    ports.adguard
    ports.grafana
  ];
}
