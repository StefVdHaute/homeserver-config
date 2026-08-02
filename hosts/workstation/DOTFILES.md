# Dotfiles on NixOS (Stow, not home-manager)

Interim arrangement for the workstation: `~/.dotfiles`
([StefVdHaute/dotfiles](https://github.com/StefVdHaute/dotfiles)) stays
GNU Stow-managed and remains the **source of truth for everything under `~`**.
NixOS's job is only to provide what those dotfiles reference. Nothing here
migrates config into Nix — that's the home-manager step, deliberately deferred.

The rule that keeps this honest: **NixOS adapts to the dotfiles, never the
other way round.** Where a dotfile genuinely cannot work unchanged, the fix
must keep the *same file* working on Arch too, because both machines stow the
same repo.

---

## Bootstrap on a fresh install

`@home` is a fresh subvolume — nothing follows from the Arch install.

```sh
git clone git@github.com:StefVdHaute/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
stow -t ~ -n */     # dry run first
stow -t ~ */
```

`stow` is in `environment.systemPackages`. Log out and back in afterwards so
the login shell picks up `/etc/set-environment`.

---

## What NixOS provides for them

| Provision | Why |
|---|---|
| `ZSH_PLUGIN_DIR` | `.zshrc` sources plugins from an Arch path. See below. |
| `mako` | The dotfiles style mako and ship no dunst config. `dunst` was removed — it was inert. |
| `adwaita-icon-theme` + a `default` cursor theme | `hypr/modules/env.lua` sets `XCURSOR_SIZE`/`HYPRCURSOR_SIZE` but no theme *name*. libwayland-cursor then asks for a theme literally called `default`, which otherwise doesn't exist, and Hyprland draws no pointer. |
| `alacritty`, `firefox`, `thunar`, `wofi` | Exactly what `hypr/modules/programs.lua` names. `programs.lua` also exports `TERMINAL`/`BROWSER`, which waybar's `$TERMINAL -e htop` depends on. |
| `waybar`, `hyprpaper`, `hypridle`, `hyprlock`, `cliphist`, `wl-clipboard`, `playerctl`, `pavucontrol`, `htop` | Referenced by the hypr and waybar configs. |

### The zsh plugin bridge

The one thing that cannot work unchanged. `zsh/.config/zsh/.zshrc` has three
`source /usr/share/zsh/plugins/<name>/…` lines, and nixpkgs has no single
layout to point at — only `zsh-autosuggestions` happens to match Arch's shape:

```
zsh-autosuggestions      share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
zsh-syntax-highlighting  share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
zsh-fzf-tab              share/fzf-tab/fzf-tab.plugin.zsh
```

`configuration.nix` builds `zsh-plugins-archlayout`, a directory of symlinks
re-exposing all three in Arch's `<name>/<file>` shape, and exports its path as
`ZSH_PLUGIN_DIR` via `environment.variables` (which lands in
`/etc/set-environment`, sourced by login shells — the right scope for a shell
rc). Symlinks rather than copies: the plugins source sibling files relatively.

**Required dotfiles-side change**, which keeps Arch working untouched because
the variable is simply unset there:

```sh
source ${ZSH_PLUGIN_DIR:-/usr/share/zsh/plugins}/fzf-tab/fzf-tab.plugin.zsh
source ${ZSH_PLUGIN_DIR:-/usr/share/zsh/plugins}/zsh-autosuggestions/zsh-autosuggestions.zsh
source ${ZSH_PLUGIN_DIR:-/usr/share/zsh/plugins}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
```

`zsh-completions` needs nothing: nixpkgs ships it to `share/zsh/site-functions`
and NixOS adds that to `fpath` already.

---

## Still to resolve, dotfiles-side

- **`blueberry` is gone from nixpkgs** (removed as unmaintained upstream, which
  points at blueman). Waybar's bluetooth module is `"on-click": "blueberry"`
  and the `blueberry/` Stow package exists only to suppress its tray
  autostart. Both are dead on this host. Repoint the click at
  `blueman-manager`; `services.blueman.enable` is on.
- **`yay/`** is an AUR helper config — inert on NixOS. Harmless, just noise.
- **`fish/`** is stowed but fish is *not* installed here; the login shell is
  zsh. Either add `fish` to `systemPackages` or retire the package.
- **`bin/.local/bin/`** scripts use `#!/usr/bin/env bash|python3`, which works
  on NixOS, but `wifi-menu` and `odoo-timesheet` haven't been exercised.

## Version skew worth knowing

Arch runs **Hyprland 0.56.1**; this host pins **0.55.4** from the flake's
nixpkgs. The Lua config is supported on both — 0.55.4 links `liblua` and
carries the `lua_*` symbols, checked directly against the binary — but the
`hl.*` API surface the config is written against may differ across that gap.
If a module errors on first login, this is the first place to look.

## Verified vs not

Verified in the built closure: `ZSH_PLUGIN_DIR` is exported, all three plugin
files resolve at exactly the paths `.zshrc` sources, `mako` is present and
`dunst` gone, and `default/index.theme` is in the system icon path.

Not verified: anything requiring a login — whether the stowed configs actually
load, and the Hyprland API-skew question above.
