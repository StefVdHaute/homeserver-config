{ config, lib, pkgs, operatorPubkeyPath, ... }:

let
  # The zsh plugins in Arch's /usr/share/zsh/plugins/<name>/ layout, for the
  # Stow-managed .zshrc via ZSH_PLUGIN_DIR. Symlinks: the plugins source
  # sibling files by relative path.
  zshPluginDir = pkgs.runCommand "zsh-plugins-archlayout" { } ''
    mkdir -p $out/fzf-tab $out/zsh-autosuggestions $out/zsh-syntax-highlighting
    ln -s ${pkgs.zsh-fzf-tab}/share/fzf-tab/* $out/fzf-tab/
    ln -s ${pkgs.zsh-autosuggestions}/share/zsh/plugins/zsh-autosuggestions/* $out/zsh-autosuggestions/
    ln -s ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/* $out/zsh-syntax-highlighting/
  '';

  # The "default" cursor theme libwayland-cursor uses when XCURSOR_THEME is
  # unset; it inherits Adwaita.
  defaultCursorTheme = pkgs.runCommand "default-cursor-theme" { } ''
    mkdir -p $out/share/icons/default
    printf '[Icon Theme]\nName=default\nComment=Redirect to Adwaita\nInherits=Adwaita\n' \
      > $out/share/icons/default/index.theme
  '';

  # The LD_PRELOAD adblock shim.
  spotifyAdblock = pkgs.callPackage ../../modules/spotify-adblock/package.nix { };

  # The plugin only reads .tap helpers from its own compiled-in LIBEXECDIR, so
  # xarchiver.tap is installed into the rebuilt plugin's $out.
  thunarArchivePluginWithXarchiver = pkgs.thunar-archive-plugin.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      install -Dm555 ${pkgs.xarchiver}/libexec/thunar-archive-plugin/xarchiver.tap \
        $out/libexec/thunar-archive-plugin/xarchiver.tap
    '';
  });

  # xfce4-mime-helper alone, without xfce4-settings' .desktop files: exo
  # execs it for Thunar's "Open Terminal Here".
  xfce4MimeHelper = pkgs.runCommand "xfce4-mime-helper" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.xfce4-settings}/bin/xfce4-mime-helper $out/bin/xfce4-mime-helper
  '';

  # Runs Discord natively on Wayland; NIXOS_OZONE_WL is unset on this host.
  discordWayland = pkgs.discord.override {
    commandLineArgs =
      "--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true";
  };

  # Hyprland Lua-IPC dispatch backport for waybar 0.15.0; drop when nixpkgs
  # ships waybar > 0.15.0. Both systemd.packages and systemPackages use it.
  waybarLuaIpc =
    if pkgs.waybar.version == "0.15.0" then
      pkgs.waybar.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./waybar-hyprland-lua-ipc.patch ];
      })
    else
      lib.warn "waybar is ${pkgs.waybar.version}: the Hyprland Lua-IPC backport is obsolete, delete waybarLuaIpc and waybar-hyprland-lua-ipc.patch"
        pkgs.waybar;

  # Install this, never plain pkgs.spotify: the .desktop Exec is PATH-relative.
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

  # Limine lists this install and the Arch UKI on the other NVMe in one menu.
  #
  # secureBoot signs with the sbctl keys Arch already enrolled (/var/lib/sbctl).
  # autoGenerateKeys must stay false: new keys replace the enrolled db and
  # Arch stops booting.
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 3;
  boot.loader.limine = {
    enable = true;
    maxGenerations = 10;
    secureBoot = {
      enable = true;
      autoGenerateKeys = false;
    };
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
  boot.resumeDevice =
    "/dev/mapper/${config.disko.devices.disk.nixos.content.partitions.luks.content.name}";

  # Recreating the swapfile changes this; re-read it with
  # `btrfs inspect-internal map-swapfile -r /swap/swapfile`.
  boot.kernelParams = [ "resume_offset=533760" ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # The nixpkgs default kernel as a fallback boot entry.
  specialisation.lts.configuration = {
    boot.kernelPackages = lib.mkForce pkgs.linuxPackages;
  };

  # NumLock on at the LUKS prompt.
  boot.initrd.systemd.storePaths = [ "${pkgs.kbd}/bin/setleds" ];

  boot.initrd.systemd.services.numlock = {
    description = "Enable NumLock on the console";
    wantedBy = [ "initrd.target" ];
    after = [ "systemd-vconsole-setup.service" ];
    before = [ "cryptsetup-pre.target" "systemd-ask-password-console.service" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    script = "${pkgs.kbd}/bin/setleds -D +num < /dev/console";
  };

  # `.#workstation` evaluates only if /etc/nixos/site.nix exists as a real
  # file; do not materialize it via `environment.etc`.

  networking.hostName = "workstation";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Brussels";
  i18n.defaultLocale = "en_US.UTF-8";

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Password is set imperatively before first reboot
  # (`nixos-enter --root /mnt -- passwd stef`); without it first boot locks out.
  users.mutableUsers = true;

  users.users.stef = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" "docker" "gamemode" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keyFiles = [ operatorPubkeyPath ];
  };

  # Makes the root-owned @games subvolume writable by stef.
  systemd.tmpfiles.rules = [ "d /home/stef/Games 0755 stef users -" ];

  # Populates /bin and /usr/bin from PATH via a FUSE overlay, so non-Nix
  # shebangs resolve.
  services.envfs.enable = true;

  # uwsm runs Hyprland as a systemd user session; the desktop's user units
  # need the environment it exports.
  programs.hyprland = {
    enable = true;
    withUWSM = true;
  };
  programs.uwsm.enable = true;
  programs.hyprlock.enable = true;   # also registers the hyprlock PAM service
  programs.zsh.enable = true;

  # direnv + nix-direnv (cached devShells, GC-rooted); hooks into /etc/zshrc.
  programs.direnv.enable = true;

  programs.thunar = {
    enable = true;
    plugins = [ thunarArchivePluginWithXarchiver pkgs.thunar-volman ];
  };

  programs.firefox = {
    enable = true;
    policies.SearchEngines.Default = "DuckDuckGo";
  };

  # Opens TCP+UDP 1714-1764 for discovery on the LAN.
  programs.kdeconnect.enable = true;

  # Battery state for kdeconnect's battery plugin (and anything else that
  # asks Solid/UPower about the laptop battery).
  services.upower.enable = true;

  services.gvfs.enable = true;
  services.tumbler.enable = true;

  # extraCompatPackages adds GE-Proton to Steam's compatibility dropdown.
  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];

    # Translates X11 input events to libei for Steam Input under Wayland.
    extest.enable = true;

    protontricks.enable = true;

    # Gamescope-wrapped Big Picture session at SDDM.
    gamescopeSession.enable = true;
  };

  programs.gamescope.enable = true;

  # Games opt in with the Steam launch option `gamemoderun %command%`.
  programs.gamemode.enable = true;

  # Lets the gamemode group run gamemode's polkit helper actions without a prompt.
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

  # Opens text files in nvim; xdg-terminal-exec in systemPackages supplies
  # the terminal nvim.desktop (Terminal=true) needs.
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

  # hyprland-uwsm is the session generated by programs.uwsm.
  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;
    };
    defaultSession = "hyprland-uwsm";
  };

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    jack.enable = true;

    # Initial volume for sources with no stored route volume. Cubed amplitude:
    # 0.001 = 0.1³ is the 10% slider (ALC295 Capture 0dB, Mic Boost off).
    wireplumber.extraConfig."51-default-source-volume" = {
      "wireplumber.settings"."device.routes.default-source-volume" = 0.001;
    };
  };

  # The packages' own user units, started with the graphical session.
  systemd.packages = with pkgs; [ mako waybarLuaIpc hypridle hyprpaper ];
  systemd.user.services.mako.wantedBy = [ "graphical-session.target" ];
  systemd.user.services.waybar.wantedBy = [ "graphical-session.target" ];
  systemd.user.services.hypridle.wantedBy = [ "graphical-session.target" ];
  systemd.user.services.hyprpaper.wantedBy = [ "graphical-session.target" ];

  # PATH and TERMINAL for waybar's on-click launchers.
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
  services.blueman.enable = true;

  # Read by the Stow-managed ~/.config/zsh/.zshrc.
  environment.variables.ZSH_PLUGIN_DIR = "${zshPluginDir}";

  # RADV (Vulkan) ships inside mesa.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.fwupd.enable = true;
  services.fprintd.enable = true;
  services.ratbagd.enable = true;   # piper is its GUI

  # Makes the battery charge-limit node writable by wheel, for the dotfiles'
  # battery-charge-limit script. The EC persists the value across reboots.
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

  # Authenticate once with `tailscale up`.
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
      "discord"
      "discord-unwrapped"
      "spotify"
      "clion"
      "pycharm"
      "rider"
      "webstorm"
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
    waybarLuaIpc       # pkgs.waybar + the Hyprland Lua-IPC backport
    wofi
    mako
    hyprpaper
    hypridle
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
    polkit_gnome        # polkit agent, started from XDG autostart by uwsm
    xfce4MimeHelper     # Thunar's "Open Terminal Here"
    xdg-terminal-exec   # the terminal GLib uses for Terminal=true
    qt6.qtwayland
    adwaita-icon-theme       # real XCURSOR theme…
    defaultCursorTheme       # …plus the "default" name Wayland clients ask for
    gnome-themes-extra       # Adwaita-dark for GTK3 and Qt; gtk+3 ships neither

    # Shell + CLI
    bash
    python3           # interpreter for Claude Code plugin hooks (hookify)
    neovim            # plugins come from the Stow-managed ~/.config/nvim
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

    # Phone
    android-tools      # adb + fastboot
    scrcpy             # phone screen mirror + control over adb
    sshfs              # kdeconnect's "browse files" mounts the phone with it

    # Apps
    spotifyAdblocked   # pkgs.spotify + the LD_PRELOAD adblock shim
    discordWayland     # pkgs.discord + the Wayland flags its wrapper gates off
    gimp
    blender
    (callPackage ../../modules/blender-mcp/package.nix { })
    kicad
    mpv
    qbittorrent
    gnome-calculator
  ];

  # Fallback allow/deny lists for spotifyAdblock; ~/.config/spotify-adblock/
  # config.toml overrides it. Without either, the shim aborts Spotify on startup.
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
