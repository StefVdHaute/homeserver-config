{ config, lib, pkgs, operatorPubkeyPath, sitePath, ... }:

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

  # Materialize the `site` flake input at its canonical path, same as main
  # does. This host never reads `siteConfig`, but flake inputs are fetched
  # eagerly, so `.#workstation` will not evaluate at all without the file
  # present — verified empirically, see MIGRATION.md. Without this line the
  # installed system can't rebuild itself.
  #
  # Note this does not bootstrap: `environment.etc` can only place the file
  # if the machine doing the evaluation already has it. A fresh install
  # needs one manual copy before its first rebuild; from then on this keeps
  # it in place. Same caveat as main — after editing site.nix and relocking,
  # the first rebuild must run somewhere the real file already lives.
  environment.etc."nixos/site.nix".source = sitePath;

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
    extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" "docker" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keyFiles = [ operatorPubkeyPath ];
  };

  # The @games subvolume's root inode is created root-owned, so Steam (running
  # as stef) can't write into it. NixOS fixes /home/stef itself on every
  # activation, but not a nested mount — hence this. `d` adjusts an existing
  # directory's owner and mode, and tmpfiles runs after local-fs.target.
  systemd.tmpfiles.rules = [ "d /home/stef/Games 0755 stef users -" ];

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
  programs.thunar = {
    enable = true;
    plugins = with pkgs; [ thunar-archive-plugin thunar-volman ];
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

  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-hyprland
      pkgs.xdg-desktop-portal-gtk
    ];
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

  # polkit_gnome ships only an XDG autostart entry marked
  # OnlyShowIn=GNOME;XFCE, which never fires under Hyprland — so the agent
  # needs an explicit unit. uwsm reaches graphical-session.target only after
  # importing the session environment, so order against that.
  systemd.user.services."polkit-gnome-authentication-agent-1" = {
    description = "polkit-gnome-authentication-agent-1";
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
      RestartSec = 1;
      TimeoutStopSec = 10;
    };
  };

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    jack.enable = true;
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

  # No authKeyFile here, deliberately — authenticate once with `sudo tailscale
  # up`. /etc/tailscale/authkey is the *Pi's* mechanism (it has no operator at
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
    qt6.qtwayland
    # NOTE: blueberry is NOT available — nixpkgs removed it as unmaintained
    # upstream and points at blueman. The dotfiles' waybar bluetooth module is
    # `"on-click": "blueberry"` and the blueberry Stow package suppresses its
    # tray autostart; both are dead weight on this host. Fixing that is a
    # dotfiles-side change (point the click at blueman-manager), not something
    # this file can paper over. See DOTFILES.md.
    adwaita-icon-theme       # real XCURSOR theme…
    defaultCursorTheme       # …plus the "default" name Wayland clients ask for

    # Shell + CLI
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
    piper
    nvtopPackages.amd
    gparted
    qdirstat
    xarchiver

    # Apps
    # Bitwarden is used via the Firefox extension + the self-hosted Vaultwarden
    # web vault; the desktop app pulls an EOL Electron. See MIGRATION.md.
    firefox
    spotify
    gimp
    blender
    mpv
  ];

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
