# Dotfiles on NixOS (Stow, moving to Home Manager)

`~/.dotfiles` ([StefVdHaute/dotfiles](https://github.com/StefVdHaute/dotfiles))
remains the **source of truth for everything under `~`**. Most of it is still
GNU Stow-managed, and NixOS's job there is only to provide what those dotfiles
reference. The configs moved off Stow are Home Manager modules in the repo's
`home/` (its `home/README.md` lists them); `home.nix` imports them from the
dotfiles flake, and the Arch install applies the same modules standalone.

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

## Home Manager

`home-manager-stef.service` applies the dotfiles' `homeModules.default` on
every switch. The dotfiles repo is private, so the flake fetches it over SSH
with the key of whoever evaluates: `nixup` runs `nixos-rebuild --sudo`, which
evaluates as stef and elevates only to activate. Stef's GitHub SSH key must
work here (`ssh -T git@github.com`).

The work email stays out of git, in a per-host `~/.config/git/private`
(`[user]` / `email = ...`). A clone's own `user.email` would override the
personal no-reply address, so leave none set.

A config moving from Stow to Home Manager disappears from the
Stow tree, so unstow it here **before** pulling the dotfiles commit that moves
it: Stow finds its links through the package's files. For the first batch
(fonts, git, ssh, tmux, and `systemd`'s `environment.d`):

```sh
cd ~/.dotfiles
stow -t ~ -D git ssh tmux fontconfig systemd
git pull
stow -t ~ systemd     # its two units stay Stow-managed
nixup                 # once homeserver-config locks the new dotfiles commit
```

A link missed here gets renamed to `*.pre-hm` rather than failing the switch
(`backupFileExtension` in `home.nix`). Home Manager also writes
`~/.config/systemd/user/tray.target`: if `~/.config/systemd` is itself a
folded Stow link, that file would land inside the dotfiles repo, so check with
`ls -ld ~/.config/systemd ~/.config/systemd/user` first.

---

## What NixOS provides for them

| Provision | Why |
|---|---|
| `ZSH_PLUGIN_DIR` | `.zshrc` sources plugins from an Arch path. See below. |
| `mako` | The dotfiles style mako and ship no dunst config. `dunst` was removed — it was inert. |
| `adwaita-icon-theme` + a `default` cursor theme | `hypr/modules/env.lua` sets `XCURSOR_SIZE`/`HYPRCURSOR_SIZE` but no theme *name*. libwayland-cursor then asks for a theme literally called `default`, which otherwise doesn't exist, and Hyprland draws no pointer. |
| `alacritty`, `firefox`, `thunar`, `wofi` | Exactly what `hypr/modules/programs.lua` names. `programs.lua` also exports `TERMINAL`/`BROWSER`, which the bar's `$TERMINAL -e htop` depends on. |
| `quickshell`, `hyprpaper`, `hypridle`, `hyprlock`, `cliphist`, `wl-clipboard`, `playerctl`, `pavucontrol`, `htop` | Referenced by the hypr and quickshell configs. |
| `libnotify`, `glab`, `gh`, `proton-pass-cli`, GOA + `gnome-online-accounts-gtk`, gnome-keyring | The bar's widgets and their `bin/` backends (`agenda`, `forge-status`, `mail-status`); `quickshell/README.md` has the per-widget list. |

### The Quickshell bar

`quickshell.service` is a Stow-managed user unit, not a NixOS one; enable it
once with `systemctl --user enable --now quickshell.service`. It starts
`/usr/bin/env quickshell`: systemd resolves a bare `ExecStart` name only in
`/usr/bin` and the like, and the user manager's PATH (which uwsm fills,
`~/.local/bin` included) is what finds both quickshell and the `bin/` scripts
the bar calls by name.

Not on this host: the rig gateway (`system/README.md`). Its widget hides
without a `rig-gateway` NM profile.

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

- **`blueberry/`** only suppresses a tray applet nixpkgs no longer ships —
  inert here. The bar's Bluetooth click opens `blueman-manager` when present.
- **`yay/`** is an AUR helper config — inert on NixOS. Harmless, just noise.
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
