# Dotfiles on the workstation

`~/.dotfiles` (StefVdHaute/dotfiles) owns everything under `~`. Most of it is
GNU Stow packages. Its `home/` directory holds Home Manager modules, which
this flake takes as the `dotfiles` input and applies for `stef`.

Rule: NixOS adapts to the dotfiles. If a dotfile cannot work unchanged, the
fix must keep the same file correct on Arch, which stows the same repo.

## Bootstrap

```sh
git clone git@github.com:StefVdHaute/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
stow -t ~ -n */ && stow -t ~ */
systemctl --user enable --now quickshell.service
systemctl --user enable theme-mode.service
```

`stow */` skips `home/`. The system switch applies that through
`home-manager-stef.service`.

## Applying a change in `home/`

Push the dotfiles, then here: `nix flake update dotfiles`, push, and `nixup`.

## What NixOS provides for the dotfiles

| Provision | For |
|---|---|
| `ZSH_PLUGIN_DIR` | `.zshrc` sources its plugins from `${ZSH_PLUGIN_DIR:-/usr/share/zsh/plugins}/<name>/`. nixpkgs has no such layout, so `zsh-plugins-archlayout` links the three plugins into it. |
| `adwaita-icon-theme` and a `default` cursor theme | `hypr/modules/env.lua` sets a cursor size but no theme name, and Wayland clients then ask for a theme called `default`. |
| `alacritty`, `firefox`, `thunar`, `wofi` | Named by `hypr/modules/programs.lua`. |
| `quickshell`, `mako`, `hyprpaper`, `hypridle`, `hyprlock`, `cliphist`, `wl-clipboard`, `playerctl`, `pavucontrol`, `htop` | Called by the hypr and quickshell configs. |
| `libnotify`, `glab`, `gh`, `proton-pass-cli`, GNOME Online Accounts, gnome-keyring | The bar's widgets and their `bin/` scripts. The dotfiles' `quickshell/README.md` has the list per widget. |
| `kdePackages.breeze` and `/share/color-schemes` | `theme-mode` reads the Breeze colour schemes. |
| The udev rule on `BAT1/charge_control_end_threshold` | `battery-charge-limit` writes that node. |
| Wayland flags in the `spotifyAdblocked` wrapper | `spotify-flags.conf` is read only by Arch's launcher. |

Inert on this host: the dotfiles' `blueberry/`, `yay/` and `system/`.
