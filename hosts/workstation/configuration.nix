{ config, lib, pkgs, operatorPubkeyPath, sitePath, ... }:

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
  };
  programs.gamescope.enable = true;

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

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

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

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    authKeyFile = "/etc/tailscale/authkey";
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
    dunst
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
