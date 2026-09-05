{ config, lib, pkgs, operatorPubkeyPath, ... }:

let
  # Bridge for the Stow-managed dotfiles, which stay the source of truth for
  # everything under ~ (see hosts/workstation/DOTFILES.md). They are written
  # for Arch, and the one thing that genuinely cannot work unchanged is
  # ~/.config/zsh/.zshrc sourcing plugins from /usr/share/zsh/plugins/<name>/.
  #
  # nixpkgs does not agree on a layout — only zsh-autosuggestions happens to
  # match Arch's, under a different prefix:
  #
  #   zsh-autosuggestions     share/zsh/plugins/zsh-autosuggestions/…zsh
  #   zsh-syntax-highlighting share/zsh-syntax-highlighting/…zsh
  #   zsh-fzf-tab             share/fzf-tab/fzf-tab.plugin.zsh
  #
  # So re-expose all three in Arch's shape and hand the path to .zshrc via
  # ZSH_PLUGIN_DIR. The dotfiles then read
  # ${ZSH_PLUGIN_DIR:-/usr/share/zsh/plugins}, which keeps the *same* file
  # working unmodified on Arch, where the variable is simply unset. Symlinks,
  # not copies: the plugins source sibling files by relative path.
  zshPluginDir = pkgs.runCommand "zsh-plugins-archlayout" { } ''
    mkdir -p $out/fzf-tab $out/zsh-autosuggestions $out/zsh-syntax-highlighting
    ln -s ${pkgs.zsh-fzf-tab}/share/fzf-tab/* $out/fzf-tab/
    ln -s ${pkgs.zsh-autosuggestions}/share/zsh/plugins/zsh-autosuggestions/* $out/zsh-autosuggestions/
    ln -s ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/* $out/zsh-syntax-highlighting/
  '';

  # libwayland-cursor resolves a theme name against XCURSOR_PATH and falls back
  # to one named literally "default" when XCURSOR_THEME is unset. The dotfiles'
  # hypr/modules/env.lua sets XCURSOR_SIZE and HYPRCURSOR_SIZE but no theme
  # name, so without this Hyprland has no pointer to draw.
  defaultCursorTheme = pkgs.runCommand "default-cursor-theme" { } ''
    mkdir -p $out/share/icons/default
    printf '[Icon Theme]\nName=default\nComment=Redirect to Adwaita\nInherits=Adwaita\n' \
      > $out/share/icons/default/index.theme
  '';

  # The LD_PRELOAD adblock shim. Built from modules/spotify-adblock/package.nix,
  # which is also a flake output so nix-update can bump it against upstream's
  # GitHub releases — see that file's header. The environment.etc entry further
  # down plants the config it ships as the system-wide fallback.
  spotifyAdblock = pkgs.callPackage ../../modules/spotify-adblock/package.nix { };

  # thunar-archive-plugin resolves its helper script as
  # LIBEXECDIR/thunar-archive-plugin/<desktop-id>.tap, and LIBEXECDIR is
  # compiled into the .so — so it only ever looks inside its *own* store path.
  # The taps it ships there are for file-roller, engrampa and ark. xarchiver
  # does ship the matching xarchiver.tap, but under xarchiver's own prefix,
  # which the plugin never reads. With xarchiver the only registered handler
  # for archive MIME types, the candidate list filters down to empty and every
  # context-menu entry fails with "No suitable archive manager found".
  #
  # overrideAttrs is what makes this fixable: it rebuilds the plugin, so the
  # LIBEXECDIR baked into the .so is the same fresh $out that postInstall drops
  # the script into. A symlinkJoin or a wrapper cannot work here — they produce
  # a path the compiled-in constant does not point at.
  thunarArchivePluginWithXarchiver = pkgs.thunar-archive-plugin.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      install -Dm555 ${pkgs.xarchiver}/libexec/thunar-archive-plugin/xarchiver.tap \
        $out/libexec/thunar-archive-plugin/xarchiver.tap
    '';
  });

  # Thunar's "Open Terminal Here" runs, verbatim, `exo-open --launch
  # TerminalEmulator`. Since Xfce 4.18 exo does not resolve that itself any
  # more — libexo execs `xfce4-mime-helper --launch TerminalEmulator`, and that
  # binary lives in xfce4-settings. nixpkgs' thunar wrapper prefixes PATH with
  # exo alone (nixpkgs#329688), so the helper is on no PATH at all and the menu
  # entry fails silently: exit 1, no window, no message.
  #
  # The helper needs no configuration. Its own bin/ wrapper prefixes
  # XDG_DATA_DIRS with the share/xfce4/helpers it ships, and that set includes
  # alacritty.desktop, so it finds the terminal already on PATH. Neither
  # ~/.config/xfce4/helpers.rc nor a TerminalEmulator= entry is required.
  #
  # A symlink to the single binary, not the whole package: xfce4-settings also
  # ships 13 .desktop files for the Xfce settings dialogs (display, keyboard,
  # mouse, appearance…). Each one wants xfsettingsd and means nothing under
  # Hyprland, but wofi reads share/applications and would list all of them. The
  # symlink is enough because bin/xfce4-mime-helper is a makeCWrapper binary
  # that execs its payload by absolute store path.
  xfce4MimeHelper = pkgs.runCommand "xfce4-mime-helper" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.xfce4-settings}/bin/xfce4-mime-helper $out/bin/xfce4-mime-helper
  '';

  # Discord is Electron, and nixpkgs' wrapper only adds the Wayland flags when
  # NIXOS_OZONE_WL and WAYLAND_DISPLAY are both set (linux.nix:230). Nothing
  # sets the former here — neither the Hyprland module nor the Stow-managed
  # hypr/modules/env.lua — so out of the box it renders through XWayland,
  # which the internal display's scale = 1.25 turns into blurry text.
  #
  # commandLineArgs rather than the global variable: NIXOS_OZONE_WL would also
  # reach pkgs.spotify, whose wrapper reacts to it by unsetting DISPLAY, and
  # switching a working Spotify's rendering path is not part of installing a
  # chat client. These are verbatim the flags the gate would have added.
  discordWayland = pkgs.discord.override {
    commandLineArgs =
      "--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true";
  };

  # Wrap rather than override: pkgs.spotify is an unpacked snap that already
  # carries its own makeWrapper layer, and LD_PRELOAD set on the outside
  # propagates through it to the real binary. Its .desktop file ships
  # `Exec=spotify %U` — PATH-relative, so the launcher picks this wrapper up
  # too, provided this is what systemPackages installs and plain pkgs.spotify
  # never is.
  spotifyAdblocked = pkgs.symlinkJoin {
    name = "spotify-adblocked";
    paths = [ pkgs.spotify ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/spotify \
        --set LD_PRELOAD ${spotifyAdblock}/lib/libspotifyadblock.so
    '';
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
  ];

  # Limine rather than systemd-boot: it can address partitions on other disks,
  # so a single menu lists both this install and the Arch install on the other
  # NVMe. Arch's UKI is chainloaded, which Limine deliberately exempts from its
  # own hash checks because firmware LoadImage verifies the signature against
  # the enrolled db key — so nothing here changes when Arch's kernel updates.
  #
  # secureBoot signs with the sbctl keys Arch already enrolled (/var/lib/sbctl).
  # autoGenerateKeys must stay false: minting a new PK/KEK/db would replace the
  # enrolled db and Arch would stop booting. See MIGRATION.md.
  boot.loader.efi.canTouchEfiVariables = true;
  # Limine's menu countdown was costing ~7s per boot. 3s is still enough to
  # catch the menu and pick the Arch entry on the days that's wanted.
  boot.loader.timeout = 3;
  boot.loader.limine = {
    enable = true;
    maxGenerations = 10;
    secureBoot = {
      enable = true;
      autoGenerateKeys = false;
    };
    # `protocol: efi`, not `chainload` — Limine 12 has no protocol by that
    # name and panics with "Unsupported protocol specified." at entry select.
    # The accepted names in the 12.4.1 binary are linux / limine / multiboot{,1,2}
    # / efi / efi_chainload / bios_chainload; `chainload` is only an internal
    # function symbol. nixpkgs' own generator writes `protocol: efi` + `path:`
    # for its Xen EFI entry (limine-install.py:250), which is the same shape.
    extraEntries = ''
      /Arch Linux
          protocol: efi
          path: uuid(b57468df-5404-499b-b84e-5b8ea0108ce6):/EFI/Linux/arch-linux.efi

      /Arch Linux (fallback initramfs)
          protocol: efi
          path: uuid(b57468df-5404-499b-b84e-5b8ea0108ce6):/EFI/Linux/arch-linux-fallback.efi
    '';
  };

  # Hibernate target is the btrfs swapfile declared in disko.nix.
  #
  # Read the mapper name back out of disko rather than repeating it: a
  # hardcoded copy that drifts from disko.nix's luks `name` still boots and
  # still evaluates, and only shows up as hibernate silently not resuming.
  # Via the option, a rename over there either follows here or fails loudly
  # at eval.
  boot.resumeDevice =
    "/dev/mapper/${config.disko.devices.disk.nixos.content.partitions.luks.content.name}";

  # resume_offset can only be read off the real filesystem and disko cannot
  # emit it (disko#651), so it is measured once and pinned here. Taken
  # 2026-08-02 from the installed swapfile with `btrfs inspect-internal
  # map-swapfile -r /mnt/swap/swapfile` — note map-swapfile, NOT filefrag,
  # which reports the wrong value on btrfs. Recreating the swapfile changes
  # the offset; a stale value makes resume silently no-op rather than fail
  # loudly, and under Secure Boot it can't be corrected from the boot menu
  # (signed cmdline, editor disabled) — recovery is an older generation.
  boot.kernelParams = [ "resume_offset=533760" ];

  # Latest mainline rather than the nixpkgs default. 7.2 carries the newer
  # amdgpu and cros_ec work this laptop benefits from; the default is 6.18.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # …and the nixpkgs default kernel stays reachable as a boot entry, for the
  # release where a mainline bump breaks amdgpu, suspend, or the out-of-tree
  # framework-laptop-kmod. `pkgs.linuxPackages`, not a pinned series: a pinned
  # one goes EOL and is dropped from nixpkgs, which fails at eval.
  #
  # mkForce because the line above sets the same option at normal priority,
  # and a specialisation merges with its parent.
  #
  # The Limine module renders this: each generation becomes a submenu holding
  # "Default" first, then one entry per specialisation, and it moves
  # default_entry from 2 to 3 so "Default" — the latest kernel — stays the
  # boot default. extraEntries (Arch) are appended after, so they do not shift
  # that index.
  specialisation.lts.configuration = {
    boot.kernelPackages = lib.mkForce pkgs.linuxPackages;
  };

  # Without NumLock the numpad sends arrows, so a passphrase with digits in it
  # can't be typed at the LUKS prompt. systemd has no NumLock support of its
  # own, and kbd is in the initrd with only loadkeys and setfont — makeInitrdNG
  # copies just the files it is handed, so setleds has to be named too.
  boot.initrd.systemd.storePaths = [ "${pkgs.kbd}/bin/setleds" ];

  boot.initrd.systemd.services.numlock = {
    description = "Enable NumLock on the console";
    wantedBy = [ "initrd.target" ];
    after = [ "systemd-vconsole-setup.service" ];
    before = [ "cryptsetup-pre.target" "systemd-ask-password-console.service" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    # /dev/console because that is the terminal the password agent prompts on.
    script = "${pkgs.kbd}/bin/setleds -D +num < /dev/console";
  };

  # `/etc/nixos/site.nix` must exist here as a REAL file even though this host
  # never reads `siteConfig` — flake inputs are fetched eagerly, so
  # `.#workstation` will not evaluate without it (verified empirically, see
  # MIGRATION.md).
  #
  # It is deliberately NOT materialized via `environment.etc`; that is what
  # created the symlink cycle described in hosts/main/configuration.nix.

  networking.hostName = "workstation";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Brussels";
  i18n.defaultLocale = "en_US.UTF-8";

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Password is set imperatively at install time (`nixos-enter --root /mnt --
  # passwd stef` before first reboot) and persists in /etc/shadow — nothing in
  # git. Explicit because first boot is a lockout if that step is skipped.
  users.mutableUsers = true;

  users.users.stef = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" "docker" "gamemode" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keyFiles = [ operatorPubkeyPath ];
  };

  # The @games subvolume's root inode is created root-owned, so Steam (running
  # as stef) can't write into it. NixOS fixes /home/stef itself on every
  # activation, but not a nested mount — hence this. `d` adjusts an existing
  # directory's owner and mode, and tmpfiles runs after local-fs.target.
  systemd.tmpfiles.rules = [ "d /home/stef/Games 0755 stef users -" ];

  # Populate /bin and /usr/bin from PATH via a FUSE overlay, so scripts with
  # non-Nix shebangs resolve instead of dying on a bad interpreter. NixOS
  # otherwise ships only /bin/sh and /usr/bin/env.
  services.envfs.enable = true;

  # uwsm starts Hyprland as a proper systemd user session, which is what
  # exports WAYLAND_DISPLAY / HYPRLAND_INSTANCE_SIGNATURE into the systemd
  # user environment — the waybar / hypridle / hyprpaper / hyprpolkitagent
  # user units all fail to start without it.
  programs.hyprland = {
    enable = true;
    withUWSM = true;
  };
  programs.uwsm.enable = true;
  programs.hyprlock.enable = true;   # also registers the hyprlock PAM service
  programs.zsh.enable = true;

  # direnv + nix-direnv, so a project's toolchain activates on `cd` from its own
  # flake instead of being added to systemPackages or a profile. nix-direnv is
  # the half that makes that affordable, and it is on by default here: it caches
  # the evaluated devShell and registers it as a GC root, so re-entering a
  # project is instant and the weekly `nix.gc` below cannot collect a shell
  # that is still in use.
  #
  # The zsh hook is appended to /etc/zshrc via programs.zsh.interactiveShellInit
  # (enableZshIntegration defaults true). It registers into the
  # `precmd_functions` array, while the Stow-managed ~/.config/zsh/.zshrc
  # defines a `precmd` function — separate zsh mechanisms that both run, so the
  # dotfiles need no matching change and keep working unmodified on Arch.
  # Takes effect on next login, not on switch.
  programs.direnv.enable = true;

  programs.thunar = {
    enable = true;
    plugins = [ thunarArchivePluginWithXarchiver pkgs.thunar-volman ];
  };

  programs.firefox = {
    enable = true;
    policies.SearchEngines.Default = "DuckDuckGo";
  };

  services.gvfs.enable = true;
  services.tumbler.enable = true;

  # Steam needs the module, not a bare package — it brings the FHS wrapper,
  # 32-bit graphics libs and controller udev rules. extraCompatPackages puts
  # GE-Proton on STEAM_EXTRA_COMPAT_TOOLS_PATHS, so it shows up in Steam's
  # compatibility dropdown declaratively instead of via protonup-qt.
  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];

    # Preloads libextest.so to translate X11 input events to libei. This is
    # the Wayland controller fix — without it Steam Input misreads or ignores
    # gamepads under Hyprland. Cheap and only affects Steam's own process.
    extest.enable = true;

    # winetricks against a Proton prefix — the standard way to fix a single
    # misbehaving game (missing runtime, DLL override) without touching the
    # others.
    protontricks.enable = true;

    # Offers a gamescope-wrapped Big Picture session at SDDM, alongside the
    # Hyprland ones. Uses programs.gamescope below.
    gamescopeSession.enable = true;
  };

  # capSysNice deliberately left at its default of false: granting it is a
  # known cause of gamescope failing to launch at all, and it's far easier to
  # turn on later than to debug during a fresh install.
  programs.gamescope.enable = true;

  # Feral GameMode. Games opt in (Steam launch option `gamemoderun %command%`),
  # and while one is running it switches the CPU governor to performance and
  # raises I/O priority, reverting on exit. Nothing happens until a game asks.
  programs.gamemode.enable = true;

  # gamemode's shipped polkit policy sets allow_active=no on all four of its
  # helper actions, so pkexec refuses them for every user and no password
  # prompt can override that — authorization has to come from a rule. The
  # module creates the gamemode group and enables polkit but ships no such
  # rule, so until now every launch logged "Failed to update cpu governor
  # policy" and the governor stayed on powersave. The prefix match covers all
  # four helpers; gamemode only invokes the ones its own config asks for.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id.indexOf("com.feralinteractive.GameMode.") == 0 &&
          subject.isInGroup("gamemode")) {
        return polkit.Result.YES;
      }
    });
  '';

  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-hyprland
      pkgs.xdg-desktop-portal-gtk
    ];
  };

  # Open text files in nvim from Thunar. Two separate things are needed, and
  # neither is xfce4-mime-helper — that helper only resolves the four exo
  # categories (WebBrowser, MailReader, FileManager, TerminalEmulator) and
  # never touches MIME associations.
  #
  # 1. The association below. nvim.desktop already declares text/plain and the
  #    source types, but a declared MimeType is only a candidate; without a
  #    [Default Applications] entry Thunar has no default to pick.
  #
  # 2. xdg-terminal-exec, in systemPackages. nvim.desktop is Terminal=true, so
  #    GLib has to supply the terminal. Its list is xdg-terminal-exec,
  #    gnome-terminal, mate-terminal, xfce4-terminal, io.elementary.terminal,
  #    tilix, konsole, nxterm, color-xterm, rxvt, dtterm — alacritty is in none
  #    of them, and no other entry is installed. So every Terminal=true launch
  #    died with "Unable to find terminal required for application".
  #    xdg-terminal-exec comes first in that list and reads Alacritty.desktop
  #    (Categories=…;TerminalEmulator;), which resolves to `alacritty -e`.
  #
  # text/markdown is not in nvim.desktop's MimeType list. An explicit default
  # still wins — GLib honours the entry rather than filtering on MimeType.
  xdg.mime.defaultApplications =
    let
      nvim = "nvim.desktop";
    in
    {
      "text/plain" = nvim;
      "text/markdown" = nvim;
      "text/english" = nvim;
      "text/x-makefile" = nvim;
      "text/x-c" = nvim;
      "text/x-chdr" = nvim;
      "text/x-csrc" = nvim;
      "text/x-c++" = nvim;
      "text/x-c++hdr" = nvim;
      "text/x-c++src" = nvim;
      "text/x-java" = nvim;
      "text/x-pascal" = nvim;
      "text/x-tcl" = nvim;
      "text/x-tex" = nvim;
      "application/x-shellscript" = nvim;
    };

  # SDDM reads session .desktop files, so it picks up the hyprland-uwsm
  # session generated by programs.uwsm — no hand-written launch command.
  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;
    };
    defaultSession = "hyprland-uwsm";
  };

  # No explicit polkit agent unit here. nixpkgs ships its own copy of
  # polkit-gnome-authentication-agent-1.desktop with the OnlyShowIn line
  # commented out, so uwsm starts the agent from XDG autostart as
  # app-polkit\x2d…@autostart.service. A second, explicit unit loses the
  # race, and one sat permanently failed here until 2026-08-30.
  # polkit_gnome stays in systemPackages: that autostart file comes from it.

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    jack.enable = true;

    # The ALC295 exposes Mic Boost (0…+30dB) stacked on Capture Volume
    # (-17.25…+30dB) as one merged ramp, so a source volume of 1.0 puts the
    # internal mic at +60dB — far enough past unity that the codec's own noise
    # floor arrives as loud static rather than as speech. WirePlumber ships
    # device.routes.default-sink-volume at 0.064 but default-source-volume at
    # 1.0, and that asymmetry is exactly how a freshly-enumerated mic lands
    # there with nobody having touched a slider.
    #
    # These are cubed amplitudes, not slider percentages: 0.001 = 0.1³ is the
    # 10% slider, which on this codec means Capture at its 0dB step with Mic
    # Boost off. Setting 0.1 here would ask for a ~46% slider (+32dB) and make
    # things worse.
    #
    # Only consulted when a route has no stored volume — device.restore-routes
    # still wins for anything already in ~/.local/state/wireplumber/
    # default-routes, so this is the floor under a lost or first-boot state,
    # not a pin on the internal mic. It is also global to every source: a USB
    # headset whose own capture range is just -30…+3dB comes back too quiet
    # instead of too loud if its state is ever lost, which is the better
    # direction to fail in.
    wireplumber.extraConfig."51-default-source-volume" = {
      "wireplumber.settings"."device.routes.default-source-volume" = 0.001;
    };
  };

  # environment.systemPackages does not install a package's systemd units, and
  # NixOS ignores their [Install] section, so both halves are needed. The units
  # are the packages' own; each is already PartOf/After graphical-session.target.
  # Nothing execs these from the hypr config — the desktop expects user units,
  # which is what uwsm is for.
  systemd.packages = with pkgs; [ mako waybar hypridle hyprpaper ];
  systemd.user.services.mako.wantedBy = [ "graphical-session.target" ];
  systemd.user.services.waybar.wantedBy = [ "graphical-session.target" ];
  systemd.user.services.hypridle.wantedBy = [ "graphical-session.target" ];
  systemd.user.services.hyprpaper.wantedBy = [ "graphical-session.target" ];

  # As a systemd user unit, waybar inherits only the manager's minimal PATH and
  # no TERMINAL, so its on-click launchers (blueman, the system monitor,
  # pavucontrol, wifi-menu, calendar) resolve nothing and silently no-op. Give
  # it the session's stable PATH entries + TERMINAL. (An exec-once child on Arch
  # inherits these from Hyprland; a systemd unit does not.)
  systemd.user.services.waybar.environment = {
    TERMINAL = "alacritty";
    PATH = lib.mkForce (lib.concatStringsSep ":" [
      "/home/stef/.local/bin"
      "/etc/profiles/per-user/stef/bin"
      "/run/wrappers/bin"
      "/run/current-system/sw/bin"
    ]);
  };

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;   # blueberry is gone from nixpkgs, see above

  # Read by the Stow-managed ~/.config/zsh/.zshrc, which sources
  # ${ZSH_PLUGIN_DIR:-/usr/share/zsh/plugins}/… — see zshPluginDir above for
  # why the indirection exists and why Arch keeps working without it.
  # environment.variables lands in /etc/set-environment, sourced by login
  # shells, which is exactly the scope a shell rc needs.
  environment.variables.ZSH_PLUGIN_DIR = "${zshPluginDir}";

  # RADV (Vulkan) ships inside mesa on NixOS — unlike Arch there is no
  # separate vulkan-radeon package to add here.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.fwupd.enable = true;
  services.fprintd.enable = true;
  services.ratbagd.enable = true;   # piper is its GUI

  # Let wheel toggle the Framework battery charge ceiling from waybar without
  # root by making the EC threshold node group-writable. The EC persists the
  # value across reboots, so no re-apply service is needed. Paired with the
  # battery-charge-limit script + waybar custom/battery-limit module (dotfiles).
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", KERNEL=="BAT1", ATTR{charge_control_end_threshold}!="", RUN+="${pkgs.coreutils}/bin/chgrp wheel /sys/class/power_supply/BAT1/charge_control_end_threshold", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/power_supply/BAT1/charge_control_end_threshold"
  '';

  services.printing = {
    enable = true;
    cups-pdf.enable = true;
  };
  services.avahi = {
    enable = true;
    nssmdns4 = true;                # .local name resolution via nsswitch
    openFirewall = true;
  };

  virtualisation.docker.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # No authKeyFile here, deliberately — authenticate once with `tailscale up`.
  # /etc/tailscale/authkey is the *Pi's* mechanism (it has no operator at
  # the console on first boot); CLAUDE.md scopes it "Pi only" and this host
  # copied the pattern without ever creating the file.
  #
  # The cost was not a missing tailnet, it was a broken desktop.
  # tailscaled-autoconnect is WantedBy=multi-user.target, and with the file
  # absent it blocks for its full 90s timeout instead of failing fast. That
  # holds up multi-user.target and so graphical.target. uwsm waits only 60s for
  # graphical.target before giving up and tearing the session down, so login
  # lost the race by ~10s every time and bounced back to SDDM. A laptop also
  # shouldn't carry a long-lived auth key, and keys expire in 90 days anyway.
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    # Delegates control to stef so `tailscale up`/`status` need no sudo.
    extraSetFlags = [ "--operator=stef" ];
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ 41641 ];
    trustedInterfaces = [ "tailscale0" ];
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "claude-code"
      # pkgs.discord is an FHS wrapper around a separate unwrapped package
      # since the 2026-08-13 unstable roll, and both derivations carry the
      # same unfree meta — so the predicate has to name both.
      "discord"
      "discord-unwrapped"
      "spotify"
      "clion"
      "pycharm"
      "rider"
      "webstorm"
      # programs.steam installs both cfg.package and cfg.package.run.
      # proton-ge-bin and gamescope are free — no entry needed.
      "steam"
      "steam-unwrapped"
      "steam-run"
    ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };

  # Baseline CLI tools come from modules/common.nix
  environment.systemPackages = with pkgs; [
    # Wayland desktop
    alacritty
    waybar
    wofi
    mako
    hyprpaper
    hypridle           # no NixOS module for this one, unlike hyprlock
    brightnessctl
    pavucontrol
    grim
    slurp
    wl-clipboard
    cliphist
    playerctl
    wdisplays
    wev
    networkmanagerapplet
    polkit_gnome
    xfce4MimeHelper     # Thunar's "Open Terminal Here"; see the let binding
    xdg-terminal-exec   # the terminal GLib uses for Terminal=true; see xdg.mime
    qt6.qtwayland
    # NOTE: blueberry is NOT available — nixpkgs removed it as unmaintained
    # upstream and points at blueman. The dotfiles' waybar bluetooth module is
    # `"on-click": "blueberry"` and the blueberry Stow package suppresses its
    # tray autostart; both are dead weight on this host. Fixing that is a
    # dotfiles-side change (point the click at blueman-manager), not something
    # this file can paper over. See DOTFILES.md.
    adwaita-icon-theme       # real XCURSOR theme…
    defaultCursorTheme       # …plus the "default" name Wayland clients ask for
    gnome-themes-extra       # Adwaita-dark for GTK3 and Qt; gtk+3 ships neither

    # Shell + CLI
    bash
    python3           # interpreter for Claude Code plugin hooks (hookify)
    # Plain vim and nano come from modules/common.nix; this host also gets
    # neovim for the Stow-managed ~/.config/nvim. That config bootstraps
    # lazy.nvim over git, so no plugin belongs in this file.
    neovim
    stow
    file
    unzip
    jq
    ripgrep
    fd
    bat
    fzf
    fastfetch
    tmux
    zsh-autosuggestions      # sourced by the Stow-managed .zshrc
    zsh-syntax-highlighting
    zsh-completions
    zsh-fzf-tab

    # Development
    cmake
    docker-compose
    claude-code
    jetbrains.clion
    jetbrains.pycharm
    jetbrains.rider
    jetbrains.webstorm

    # System tools
    sbctl              # inspect/verify the Secure Boot chain: sbctl status|verify
    nix-update         # bumps modules/spotify-adblock: nix-update --flake spotify-adblock --version=stable
    piper
    nvtopPackages.amd
    pciutils           # lspci: friendly GPU names in waybar's custom/gpu tooltip
    gparted
    qdirstat
    xarchiver

    # Apps
    spotifyAdblocked   # pkgs.spotify + the LD_PRELOAD adblock shim
    discordWayland     # pkgs.discord + the Wayland flags its wrapper gates off
    gimp
    blender
    kicad
    mpv
    qbittorrent
  ];

  # Fallback allow/deny lists for spotifyAdblock. A per-user file at
  # ~/.config/spotify-adblock/config.toml still wins if one is ever dropped
  # there; without either, the shim aborts Spotify on startup.
  environment.etc."spotify-adblock/config.toml".source =
    "${spotifyAdblock}/share/spotify-adblock/config.toml";

  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
  ];

  system.stateVersion = "26.05";
}
