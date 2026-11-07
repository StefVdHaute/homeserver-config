# Grafana dashboard "Server health": the R720's iDRAC summary as a Grafana
# page. IPMI (sensors, power, PSUs, event log) via ipmi_exporter, disks via
# smartctl_exporter, RAID/btrfs/ECC/system via node_exporter.
# Rendered to JSON by ../monitoring.nix.

{ lib }:

let
  ds = { type = "prometheus"; uid = "prometheus"; };

  refIds = [ "A" "B" "C" "D" "E" "F" "G" "H" ];

  # t = { expr; legend ? ""; instant ? false; table ? false; }
  mkTargets = lib.imap0 (i: t: {
    datasource = ds;
    inherit (t) expr;
    legendFormat = t.legend or "";
    refId = builtins.elemAt refIds i;
    instant = t.instant or false;
    range = !(t.instant or false);
    format = if t.table or false then "table" else "time_series";
  });

  steps = list: {
    mode = "absolute";
    steps = map (s: { color = s.color; value = s.value or null; }) list;
  };

  okSteps = steps [ { color = "green"; } ];

  stat = { title, targets, gridPos, unit ? "none", mappings ? [ ], thresholds ? okSteps, decimals ? null, description ? "" }: {
    type = "stat";
    inherit title gridPos description;
    datasource = ds;
    targets = mkTargets targets;
    fieldConfig = {
      defaults = {
        inherit unit mappings thresholds;
        color.mode = "thresholds";
      } // lib.optionalAttrs (decimals != null) { inherit decimals; };
      overrides = [ ];
    };
    options = {
      reduceOptions = { calcs = [ "lastNotNull" ]; fields = ""; values = false; };
      colorMode = "background";
      graphMode = "none";
      textMode = "auto";
      justifyMode = "center";
      orientation = "auto";
      showPercentChange = false;
    };
  };

  timeseries = { title, targets, gridPos, unit ? "none", min ? null, description ? "" }: {
    type = "timeseries";
    inherit title gridPos description;
    datasource = ds;
    targets = mkTargets targets;
    fieldConfig = {
      defaults = {
        inherit unit;
        color.mode = "palette-classic";
        custom = {
          drawStyle = "line";
          lineWidth = 1;
          fillOpacity = 10;
          showPoints = "never";
          spanNulls = true;
        };
      } // lib.optionalAttrs (min != null) { inherit min; };
      overrides = [ ];
    };
    options = {
      legend = { displayMode = "table"; placement = "right"; calcs = [ "lastNotNull" "max" ]; showLegend = true; };
      tooltip = { mode = "multi"; sort = "desc"; };
    };
  };

  row = title: y: {
    type = "row";
    inherit title;
    collapsed = false;
    gridPos = { h = 1; w = 24; x = 0; inherit y; };
    panels = [ ];
  };

  # IPMI sensor states: 0 nominal, 1 warning, 2 critical, NaN n/a.
  stateMappings = [
    {
      type = "value";
      options = {
        "0" = { text = "OK"; color = "green"; index = 0; };
        "1" = { text = "Warning"; color = "yellow"; index = 1; };
        "2" = { text = "Critical"; color = "red"; index = 2; };
      };
    }
    { type = "special"; options = { match = "nan"; result = { text = "n/a"; color = "text"; index = 3; }; }; }
  ];

  allSensorStates = ''{__name__=~"ipmi_(temperature|fan_speed|voltage|current|power|sensor)_state"}'';

  gp = x: y: w: h: { inherit x y w h; };

  panels = [
    # ---------------------------------------------------------------- overview
    (row "Overview" 0)
    (stat {
      title = "Power";
      gridPos = gp 0 1 3 4;
      targets = [ { expr = "ipmi_chassis_power_state"; } ];
      mappings = [ {
        type = "value";
        options = {
          "1" = { text = "On"; color = "green"; index = 0; };
          "0" = { text = "Off"; color = "red"; index = 1; };
        };
      } ];
    })
    (stat {
      title = "Power draw";
      gridPos = gp 3 1 3 4;
      unit = "watt";
      targets = [ { expr = "ipmi_dcmi_power_consumption_current_watts or on() max(ipmi_power_watts)"; } ];
    })
    (stat {
      title = "Inlet temperature";
      gridPos = gp 6 1 3 4;
      unit = "celsius";
      targets = [ { expr = ''max(ipmi_temperature_celsius{name=~"(?i)inlet.*"})''; } ];
      thresholds = steps [ { color = "green"; } { color = "yellow"; value = 30; } { color = "red"; value = 35; } ];
    })
    (stat {
      title = "Sensors not OK";
      description = "IPMI sensors in warning or critical state. Details in 'Sensor states'.";
      gridPos = gp 9 1 3 4;
      targets = [ { expr = "count(${allSensorStates} > 0) or vector(0)"; } ];
      thresholds = steps [ { color = "green"; } { color = "red"; value = 1; } ];
    })
    (stat {
      title = "Uptime";
      gridPos = gp 12 1 3 4;
      unit = "dtdurations";
      targets = [ { expr = "node_time_seconds - node_boot_time_seconds"; } ];
    })
    (stat {
      title = "OS array (RAID 10)";
      description = "Active disks / required disks of the mdadm array holding /.";
      gridPos = gp 15 1 3 4;
      unit = "percentunit";
      targets = [ { expr = ''min(node_md_disks{state="active"} / node_md_disks_required)''; } ];
      thresholds = steps [ { color = "red"; } { color = "green"; value = 1; } ];
    })
    (stat {
      title = "SMART";
      gridPos = gp 18 1 3 4;
      targets = [ { expr = "min(smartctl_device_smart_status)"; } ];
      mappings = [ {
        type = "value";
        options = {
          "1" = { text = "All passed"; color = "green"; index = 0; };
          "0" = { text = "FAILED"; color = "red"; index = 1; };
        };
      } ];
    })
    (stat {
      title = "ECC errors (24h)";
      description = "Memory errors seen by the kernel (EDAC), correctable + uncorrectable.";
      gridPos = gp 21 1 3 4;
      targets = [ { expr = ''sum(increase({__name__=~"node_edac_(un)?correctable_errors_total"}[24h])) or vector(0)''; } ];
      decimals = 0;
      thresholds = steps [ { color = "green"; } { color = "yellow"; value = 1; } { color = "red"; value = 50; } ];
    })

    # -------------------------------------------------------- power & thermal
    (row "Power & thermal" 5)
    (timeseries {
      title = "Power consumption";
      gridPos = gp 0 6 8 8;
      unit = "watt";
      min = 0;
      targets = [
        { expr = "ipmi_dcmi_power_consumption_current_watts"; legend = "DCMI"; }
        { expr = "ipmi_power_watts"; legend = "{{name}}"; }
      ];
    })
    (timeseries {
      title = "Temperatures";
      gridPos = gp 8 6 8 8;
      unit = "celsius";
      targets = [ { expr = "ipmi_temperature_celsius"; legend = "{{name}}"; } ];
    })
    (timeseries {
      title = "Fans";
      gridPos = gp 16 6 8 8;
      unit = "rotrpm";
      min = 0;
      targets = [ { expr = "ipmi_fan_speed_rpm"; legend = "{{name}}"; } ];
    })
    (timeseries {
      title = "Power supplies: current";
      gridPos = gp 0 14 8 8;
      unit = "amp";
      min = 0;
      targets = [ { expr = "ipmi_current_amperes"; legend = "{{name}}"; } ];
    })
    (timeseries {
      title = "Power supplies: voltage";
      gridPos = gp 8 14 8 8;
      unit = "volt";
      targets = [ { expr = "ipmi_voltage_volts"; legend = "{{name}}"; } ];
    })
    {
      type = "table";
      title = "Sensor states";
      description = "Every IPMI sensor and its state as the BMC reports it (the iDRAC 'Sensors' pages).";
      gridPos = gp 16 14 8 16;
      datasource = ds;
      targets = mkTargets [ {
        expr = ''label_replace(${allSensorStates}, "kind", "$1", "__name__", "ipmi_(.*)_state")'';
        instant = true;
        table = true;
      } ];
      transformations = [ {
        id = "organize";
        options = {
          excludeByName = { Time = true; __name__ = true; instance = true; job = true; id = true; };
          indexByName = { name = 0; kind = 1; type = 2; Value = 3; };
          renameByName = { name = "Sensor"; kind = "Kind"; type = "Type"; Value = "State"; };
        };
      } ];
      fieldConfig = {
        defaults = { custom.align = "auto"; };
        overrides = [ {
          matcher = { id = "byName"; options = "State"; };
          properties = [
            { id = "mappings"; value = stateMappings; }
            { id = "custom.cellOptions"; value = { type = "color-background"; }; }
          ];
        } ];
      };
      options = { showHeader = true; cellHeight = "sm"; sortBy = [ { displayName = "State"; desc = true; } ]; };
    }
    (stat {
      title = "Power supply / chassis sensors";
      description = "Generic IPMI sensors (PSU status, redundancy, intrusion, ...).";
      gridPos = gp 0 22 16 8;
      targets = [ { expr = "ipmi_sensor_state"; legend = "{{name}}"; } ];
      mappings = stateMappings;
    })

    # ------------------------------------------------------ hardware event log
    (row "Hardware event log & memory" 30)
    (stat {
      title = "Event log entries";
      description = "Entries in the BMC's System Event Log (iDRAC: Logs > System Event Log). Also written to the journal by ipmiseld.";
      gridPos = gp 0 31 4 4;
      targets = [ { expr = "ipmi_sel_entries_count"; } ];
    })
    (stat {
      title = "Event log free space";
      gridPos = gp 4 31 4 4;
      unit = "bytes";
      targets = [ { expr = "ipmi_sel_free_space_bytes"; } ];
      thresholds = steps [ { color = "red"; } { color = "yellow"; value = 1024; } { color = "green"; value = 4096; } ];
    })
    (stat {
      title = "Memory events in the event log";
      gridPos = gp 8 31 8 4;
      targets = [ { expr = "ipmi_sel_events_count_by_name"; legend = "{{name}}"; } ];
      thresholds = steps [ { color = "green"; } { color = "yellow"; value = 1; } ];
    })
    {
      type = "table";
      title = "BMC";
      gridPos = gp 16 31 8 4;
      datasource = ds;
      targets = mkTargets [ { expr = "ipmi_bmc_info"; instant = true; table = true; } ];
      transformations = [ {
        id = "organize";
        options = {
          excludeByName = { Time = true; __name__ = true; instance = true; job = true; Value = true; };
          renameByName = {
            firmware_revision = "iDRAC firmware";
            manufacturer_id = "Manufacturer";
            system_firmware_version = "BIOS";
          };
        };
      } ];
      fieldConfig = { defaults = { }; overrides = [ ]; };
      options = { showHeader = true; cellHeight = "sm"; };
    }
    (timeseries {
      title = "ECC errors per memory controller (1h)";
      description = "Kernel EDAC counters. The iDRAC event log had multi-bit errors on DIMM_B2 (CPU2) in 2025.";
      gridPos = gp 0 35 24 8;
      targets = [
        { expr = "increase(node_edac_correctable_errors_total[1h])"; legend = "correctable mc{{controller}}"; }
        { expr = "increase(node_edac_uncorrectable_errors_total[1h])"; legend = "UNCORRECTABLE mc{{controller}}"; }
      ];
    })

    # ----------------------------------------------------------------- storage
    (row "Storage" 43)
    (stat {
      title = "mdadm failed disks";
      gridPos = gp 0 44 4 4;
      targets = [ { expr = ''sum(node_md_disks{state="failed"}) or vector(0)''; } ];
      thresholds = steps [ { color = "green"; } { color = "red"; value = 1; } ];
    })
    (stat {
      title = "btrfs device errors";
      description = "Read/write/flush/corruption/generation errors on the btrfs filesystems. A scrub repairs /mnt/data from the good copy.";
      gridPos = gp 4 44 4 4;
      targets = [ { expr = "sum(node_btrfs_device_errors_total) or vector(0)"; } ];
      thresholds = steps [ { color = "green"; } { color = "red"; value = 1; } ];
    })
    {
      type = "bargauge";
      title = "Filesystem usage";
      gridPos = gp 8 44 16 4;
      datasource = ds;
      targets = mkTargets [ {
        expr = ''1 - node_filesystem_avail_bytes{mountpoint=~"/|/mnt/data"} / node_filesystem_size_bytes{mountpoint=~"/|/mnt/data"}'';
        legend = "{{mountpoint}}";
      } ];
      fieldConfig = {
        defaults = {
          unit = "percentunit";
          min = 0;
          max = 1;
          color.mode = "thresholds";
          thresholds = steps [ { color = "green"; } { color = "yellow"; value = 0.75; } { color = "red"; value = 0.85; } ];
        };
        overrides = [ ];
      };
      options = {
        reduceOptions = { calcs = [ "lastNotNull" ]; fields = ""; values = false; };
        orientation = "horizontal";
        displayMode = "gradient";
        showUnfilled = true;
      };
    }
    {
      type = "table";
      title = "Disks (SMART)";
      gridPos = gp 0 48 14 7;
      datasource = ds;
      targets = mkTargets [
        { expr = "max by (device) (smartctl_device_smart_status)"; instant = true; table = true; }
        { expr = ''max by (device) (smartctl_device_temperature{temperature_type="current"})''; instant = true; table = true; }
        { expr = "max by (device) (smartctl_device_power_on_seconds) / 3600"; instant = true; table = true; }
        { expr = ''max by (device) (smartctl_device_attribute{attribute_name="Reallocated_Sector_Ct",attribute_value_type="raw"})''; instant = true; table = true; }
        { expr = ''max by (device) (smartctl_device_attribute{attribute_name="Current_Pending_Sector",attribute_value_type="raw"})''; instant = true; table = true; }
        { expr = ''max by (device) (smartctl_device_attribute{attribute_name="UDMA_CRC_Error_Count",attribute_value_type="raw"})''; instant = true; table = true; }
      ];
      transformations = [
        { id = "joinByField"; options = { byField = "device"; mode = "outer"; }; }
        {
          id = "organize";
          options = {
            excludeByName = { Time = true; "Time 1" = true; "Time 2" = true; "Time 3" = true; "Time 4" = true; "Time 5" = true; "Time 6" = true; };
            renameByName = {
              device = "Disk";
              "Value #A" = "SMART";
              "Value #B" = "Temp";
              "Value #C" = "Hours";
              "Value #D" = "Reallocated";
              "Value #E" = "Pending";
              "Value #F" = "CRC errors";
            };
          };
        }
      ];
      fieldConfig = {
        defaults = { custom.align = "auto"; };
        overrides = [
          {
            matcher = { id = "byName"; options = "SMART"; };
            properties = [
              { id = "mappings"; value = [ { type = "value"; options = { "1" = { text = "PASSED"; color = "green"; index = 0; }; "0" = { text = "FAILED"; color = "red"; index = 1; }; }; } ]; }
              { id = "custom.cellOptions"; value = { type = "color-background"; }; }
            ];
          }
          { matcher = { id = "byName"; options = "Temp"; }; properties = [ { id = "unit"; value = "celsius"; } ]; }
          { matcher = { id = "byName"; options = "Hours"; }; properties = [ { id = "decimals"; value = 0; } ]; }
          {
            matcher = { id = "byRegexp"; options = "Reallocated|Pending|CRC errors"; };
            properties = [
              { id = "thresholds"; value = steps [ { color = "green"; } { color = "red"; value = 1; } ]; }
              { id = "custom.cellOptions"; value = { type = "color-text"; }; }
            ];
          }
        ];
      };
      options = { showHeader = true; cellHeight = "sm"; };
    }
    (timeseries {
      title = "Disk temperatures";
      gridPos = gp 14 48 10 7;
      unit = "celsius";
      targets = [ { expr = ''smartctl_device_temperature{temperature_type="current"}''; legend = "{{device}}"; } ];
    })
    (timeseries {
      title = "mdadm resync / rebuild progress";
      gridPos = gp 0 55 12 7;
      unit = "percentunit";
      min = 0;
      targets = [ { expr = "node_md_blocks_synced / node_md_blocks"; legend = "{{device}}"; } ];
    })
    (timeseries {
      title = "Disk I/O";
      gridPos = gp 12 55 12 7;
      unit = "Bps";
      targets = [
        { expr = ''rate(node_disk_read_bytes_total{device=~"sd.*"}[$__rate_interval])''; legend = "read {{device}}"; }
        { expr = ''rate(node_disk_written_bytes_total{device=~"sd.*"}[$__rate_interval])''; legend = "write {{device}}"; }
      ];
    })

    # ------------------------------------------------------------------ system
    (row "System" 62)
    (timeseries {
      title = "CPU";
      gridPos = gp 0 63 8 7;
      unit = "percentunit";
      min = 0;
      targets = [ { expr = ''1 - avg(rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))''; legend = "busy"; } ];
    })
    (timeseries {
      title = "Memory";
      gridPos = gp 8 63 8 7;
      unit = "bytes";
      min = 0;
      targets = [
        { expr = "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes"; legend = "used"; }
        { expr = "node_memory_MemTotal_bytes"; legend = "total"; }
      ];
    })
    (timeseries {
      title = "Network";
      gridPos = gp 16 63 8 7;
      unit = "Bps";
      targets = [
        { expr = ''rate(node_network_receive_bytes_total{device!~"lo|veth.*|docker.*|br-.*|tailscale.*"}[$__rate_interval])''; legend = "in {{device}}"; }
        { expr = ''rate(node_network_transmit_bytes_total{device!~"lo|veth.*|docker.*|br-.*|tailscale.*"}[$__rate_interval])''; legend = "out {{device}}"; }
      ];
    })
  ];
in
{
  uid = "server-health";
  title = "Server health (R720)";
  tags = [ "homeserver" ];
  timezone = "browser";
  refresh = "1m";
  time = { from = "now-24h"; to = "now"; };
  schemaVersion = 39;
  version = 1;
  editable = false;
  graphTooltip = 1;
  templating.list = [ ];
  annotations.list = [ ];
  panels = lib.imap1 (i: p: p // { id = i; }) panels;
}
