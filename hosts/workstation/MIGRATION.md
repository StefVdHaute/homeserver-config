# Workstation migration checklist

Bringing `hosts/workstation/` from a skeleton to a deployable NixOS install.

**Target:** a NixOS install on a **new, second NVMe** in the Framework 16,
dual-booting alongside the existing Arch install. Work stays on Arch; the
NixOS side is a clean personal machine. Feature parity with the current Arch
environment is the goal — same desktop, same tooling, NixOS underneath.

**Current state of the machine (updated 2026-08-01):** Arch Linux on the
WD_BLACK SN850X 1000GB (LUKS + btrfs `@`/`@home`/`@swap`), now enumerating as
`nvme1n1`. The NixOS target drive — Kingston SNV3SM32T0, **2 TB**, empty — is
installed and enumerates as `nvme0n1`. **Both are addressed by `/dev/disk/by-id/`
in config; see the renumbering warning below.** Session is `hyprland-uwsm`,
login shell zsh. Nix is installed and working, so the config below is
eval-verified against locked nixpkgs (but never built or booted).

---

## Decisions locked in

Recorded so they don't get re-litigated:

| Decision | Choice |
|---|---|
| Install target | New second NVMe, dual-boot; Arch untouched |
| `/home` | Separate `@home` subvolume |
| Hibernate | **Yes** — btrfs swapfile on a `@swap` subvolume; `resume_offset` read post-install |
| Boot menu | **One unified menu, no firmware menu** — Limine on the NixOS ESP, chainloading Arch |
| Secure Boot | **Limine `secureBoot`, reusing Arch's existing sbctl keys** — never re-enrol |
| Notification daemon | **Keep `dunst`** (not mako) |
| Login shell | zsh |
| Display manager | **SDDM** — "best supported" per operator; it reads session `.desktop` files and picks up `hyprland-uwsm.desktop` automatically, exactly as on Arch today, instead of needing a hand-written `--cmd` string |
| Operator/deploy role | **NixOS takes over** managing main + Pi from Arch |
| Dotfiles | Handled in a separate session |
| Password | **Imperative, at install** — `users.mutableUsers = true` (now explicit), `passwd stef` via `nixos-enter` before first reboot. Nothing in git; agenix `hashedPasswordFile` deliberately rejected until the keys/agenix work lands, if at all |

---

## Batch 1 — in progress

- [x] **`disko.nix`: add `@home` subvolume** mounted at `/home`, matching the
      existing `@nixos` mount options. No swap yet (blocked on the hibernate
      research below). *Unverified — no `nix` on this machine to eval it.*
- [x] **uwsm fix.** `configuration.nix:51` ran `tuigreet --cmd Hyprland`,
      which launches bare Hyprland. The real session is
      `hyprland-uwsm.desktop`, and `waybar` / `hypridle` / `hyprpaper` /
      `hyprpolkitagent` are systemd **user units** that need uwsm to export
      `WAYLAND_DISPLAY` into the systemd user environment — without it all
      four start and fail. Fix: `programs.uwsm.enable`, Hyprland's uwsm
      integration, SDDM as the DM.
- [x] **zsh as login shell.** `programs.zsh.enable` + `shell = pkgs.zsh`.
      Also add the plugin packages the dotfiles source (autosuggestions,
      syntax-highlighting, completions, fzf-tab, fzf) so the deferred dotfiles
      work has something to point at.
- [x] **Package + service additions:**
  - Hyprland stack: `hypridle`, `hyprlock`, `hyprpaper`, `hyprpolkitagent`,
    `cliphist`, `playerctl`, `wdisplays`, `wev`, Qt6 Wayland
  - Laptop hardware: `fprintd`, `fwupd`, `hardware.graphics`, `ratbagd` +
    `piper`, printing + cups-pdf, avahi + mDNS
  - Docker + compose, `cmake`
  - Apps: firefox, spotify, bitwarden, JetBrains (clion/pycharm/rider/
    webstorm), gimp, blender, mpv, gparted, nvtop, qdirstat, xarchiver,
    claude-code
  - **Added 2026-08-01, eval-verified:** `programs.steam` with
    `extraCompatPackages = [ pkgs.proton-ge-bin ]` (resolves to
    `GE-Proton11-1`), plus `programs.gamescope`. Note **Steam is not installed
    on the Arch side** — this is a new addition, not parity. GE-Proton is
    declarative here rather than via protonup-qt, so it's pinned to nixpkgs and
    moves only when the flake is bumped; protonup-qt can still coexist if a
    specific newer GE build is ever needed for one game.
    `programs.gamescope.capSysNice` deliberately left at `false` — it's a known
    cause of gamescope failing to launch, and is easier to enable later than to
    debug during a first install.
  - Extend `allowUnfreePredicate` — it currently permits only `claude-code`
- [x] **Weigh `blueman` vs `blueberry`** → **keep `blueman`**, config already
      correct, no change made. Deciding factors: `services.blueman.enable` is a
      real module wiring the privileged `blueman-mechanism` helper's
      D-Bus/systemd/polkit registration; upstream active through July 2026;
      features (PAN, dial-up, OBEX) are a strict superset of blueberry's.
      Blueberry has no NixOS module, upstream untouched since April 2024,
      nixpkgs shipped identical 1.4.8 across four stable channels, and its
      "no tray icon on Wayland" issue has been open since Oct 2021 — the exact
      failure mode Hyprland would hit. Only cost is relearning the UI.
- [x] **Weigh `polkit_gnome` vs `hyprpolkitagent`** → **`polkit_gnome`**;
      `hyprpolkitagent` removed, and a `systemd.user.services` unit added
      because polkit_gnome ships only an XDG autostart entry marked
      `OnlyShowIn=GNOME;XFCE` that never fires under Hyprland. Before this, no
      polkit agent was actually running at all — the package was bare in
      `systemPackages` with nothing starting it.

      **Deciding factor:** nixpkgs 26.05 ships hyprpolkitagent **0.1.3**
      (Qt/QML), which has open issue #24, "Fingerprint has to be scanned with
      correct password" (opened 2025-01-07, still open). The agent doesn't
      follow the PAM conversation — it assumes a password prompt. With
      `pam_fprintd` in the `polkit-1` stack the password field is shown
      regardless, and the dialog won't close after a *correct* password until
      the scanner is also touched; any finger satisfies that touch because PAM
      has already been satisfied (or `pam_fprintd` times out after ~30s and
      falls through). **This is a broken auth flow, not an auth bypass** — no
      wrong finger ever grants access on its own.

      Notably, issue #24 itself cites polkit_gnome as doing this *correctly*:
      prompt for fingerprint first, fall back to a password field only after 3
      failures, which is how polkit is designed to work. That's independent
      support for the choice made here. A fix was scoped 2026-07-11 — follow
      the PAM conversation, keep the password field hidden until PAM sends
      `PAM_PROMPT_ECHO_OFF` — but it lands only in the untagged `hyprtoolkit`
      rewrite (merged 2026-06-03), and the contributor scoping it has no
      fingerprint hardware to final-test. So nixpkgs and Arch both still
      pin 0.1.3. Secondary: 0.1.3 pulls a Qt6 + KDE chain
      (`qtbase`/`qtsvg`/`qtwayland`, `kirigami-addons`, `polkit-qt-1`,
      `hyprland-qt-support`) that nothing else in this GTK/wlroots desktop
      needs.

      **Accepted downside:** polkit_gnome is upstream-archived (~2015) and its
      nixpkgs derivation has been unchanged since May 2024. A 2021 Wayland
      segfault was distro-patched at the time; nixpkgs builds the vanilla
      0.105 tarball with no patches and it could not be confirmed either way
      whether that fix is present. The combination is very common in practice.

      **Revisit when** nixpkgs packages a tagged hyprtoolkit-based release —
      at that point hyprpolkitagent becomes the better long-term fit and
      matches the Arch setup.

      **Confirmed by the operator on 2026-07-31** after reviewing the issue #24
      detail above. Decision closed — don't reopen without a tagged
      hyprtoolkit-based release to compare against.

---

## Verification results (2026-07-31)

Nix store initialised on the Arch host, so batch 1 has now been evaluated
against the locked nixpkgs (`26.05.20260724.597283a`). Both files parse, and
every flagged package attribute was resolved by a batch eval against
`nixosConfigurations.workstation.pkgs`.

Verification only — `nix eval` of `system.build.toplevel.drvPath`, nothing was
built, and the `site` input was worked around with
`--override-input site path:<stub>`.

### Three real defects found and fixed

1. **`programs.hypridle` does not exist** as a NixOS option (`programs.hyprlock`
   does). Fixed: option dropped, `hypridle` moved to `systemPackages`.
2. **`jetbrains.pycharm-professional` has been renamed to `jetbrains.pycharm`.**
   Fixed in both `systemPackages` and `allowUnfreePredicate` (the `pname` the
   predicate matches is now `pycharm`).
3. **`bitwarden-desktop` refuses to evaluate** — it pins `electron_39`
   (39.8.10), which nixpkgs marks insecure because that Electron major is EOL.
   nixpkgs' default `electron` is already 41.9.1, so the package lags a major
   behind. Verified it was the sole cause: spotify, blender, gimp and firefox
   all evaluate clean.

   **Operator decision (2026-07-31): dropped the desktop app** in favour of the
   Firefox extension plus the self-hosted Vaultwarden web vault (which already
   has real Let's Encrypt certs). Rejected alternatives:
   `permittedInsecurePackages = [ "electron-39.8.10" ]` (works, but keeps an
   unpatched Chromium under the password manager), overriding to Electron 41
   (unverified — may depend on the 39 ABI), and `bitwarden-cli-2026.4.2`
   (Electron-free but a different workflow). Revisit if a native app is wanted
   and nixpkgs has bumped the Electron pin.

### Resolved, with the versions that will be installed

`hypridle-0.1.7` · `hyprpaper-0.8.4` · `hyprpolkitagent-0.1.3` ·
`cliphist-0.7.0` · `playerctl-2.4.1` · `wdisplays-1.1.3` · `wev-1.1.0` ·
`qtwayland-6.11.1` · `polkit-gnome-0.105` · `dunst-1.13.2` ·
`zsh-autosuggestions-0.7.1` · `zsh-syntax-highlighting-0.8.0` ·
`zsh-completions-0.35.0` · `zsh-fzf-tab-1.3.0` · `fzf-0.72.0` · `cmake-4.1.6` ·
`docker-compose-5.1.4` · `clion-2026.1.4` · `pycharm-2026.1.2` ·
`rider-2026.1.4` · `webstorm-2026.1.3` · `piper-0.8` · `nvtop-3.3.2` ·
`gparted-1.8.1` · `qdirstat-2.0` · `xarchiver-0.5.4.26` · `firefox-153.0` ·
`spotify-1.2.90.451` · `bitwarden-desktop-2026.5.0` · `gimp-3.0.8` ·
`blender-5.1.1` · `mpv-0.41.0`

Incidental confirmations from the same run:

- **`bitwarden-desktop` is free** — it evaluates without an
  `allowUnfreePredicate` entry, so none was added.
- **`gimp` is 3.0.8**, not a 2.10 fallback — no `gimp`/`gimp3` split survives.
- **`zsh-fzf-tab` is the correct attr** (nixpkgs prefixes it, unlike upstream).
- **`nvtopPackages.amd` resolves** to `nvtop-3.3.2`.
- **`hyprpolkitagent` in this nixpkgs really is 0.1.3** — independently confirms
  the version the polkit research was based on, i.e. the build with issue #24.
- **`cups-pdf-to-pdf` exists** if the `services.printing.cups-pdf` module
  route ever needs the fallback.
- **The uwsm session is real.**
  `config.services.displayManager.sessionData.sessionNames` evaluates to
  `[ "hyprland" "hyprland-uwsm" ]` — so `programs.hyprland.withUWSM` does
  generate the uwsm session, and `defaultSession = "hyprland-uwsm"` names one
  that exists. Matches the Arch host's `/usr/share/wayland-sessions/` exactly.

Also cleaned up while here: `xfce.thunar-archive-plugin` and
`xfce.thunar-volman` emitted "moved to top-level" deprecation warnings (both
pre-existing, not introduced by batch 1) — switched to the top-level attrs.

### Still to check by hand after first install

- **`docker compose` as a CLI subcommand.** The package provides the binary;
  whether `docker compose` (space) works as a plugin, versus only
  `docker-compose` (hyphen), isn't something eval can answer.

Behavioural note: with `sddm.wayland.enable = true` no X server is pulled in, so
XWayland comes solely from `programs.hyprland` (on by default). That's the knob
if an X11-only app misbehaves.

---

## Boot, Secure Boot and hibernate — resolved design

**Decision: `boot.loader.limine` with `secureBoot.enable`, chainloading Arch's
existing signed UKI. Two independent ESPs. Arch changes nothing and keys are
never re-enrolled.**

✅ **Implemented and eval-verified 2026-07-31.** `limine.enable = true`,
`secureBoot.enable = true`, `systemd-boot.enable = false`,
`resumeDevice = /dev/mapper/nixos-cryptroot` — renamed from `cryptroot`
2026-08-02 because that is also Arch's mapper name, and disko's luks `name`
is used both as the `cryptsetup open` argument at install time and as the
`boot.initrd.luks.devices` key, so the original collided with the running
system and aborted the install. `configuration.nix` reads the name back out
of the disko option rather than repeating it. And disko generated
`swapDevices = [ "/swap/swapfile" ]` on its own — so `swap.swapfile.size` is the
right schema and no separate swap declaration is needed. ESP grown 1 G → 2 G for
Limine's per-generation kernel/initrd copies. Swapfile **40 G** (32 G RAM +
headroom).

The premise this repo was carrying — "one menu ⇒ GRUB/rEFInd ⇒ no Secure Boot" —
was **false**. Limine is a fourth option that satisfies every requirement at
once, and it's in nixpkgs (no external flake input, unlike lanzaboote).

Why it wins:

- **In-tree and declarative.** Module in nixpkgs since 25.05,
  `secureBoot.enable` since 25.11; 26.05 packages Limine 12.5.1.
- **Cross-disk addressing.** `uuid()`/`guid()`/`fslabel()`/`hdd()` reach
  partitions on any disk (only `boot()` is boot-drive-local) — the thing
  sd-boot fundamentally cannot do.
- **Chainloading Arch needs no maintenance.** `common/protos/chainload.c`
  deliberately exempts chainloads from Limine's own hash enforcement: "The
  firmware's LoadImage will verify the Secure Boot signature of the chainloaded
  EFI application, so Limine does not need to enforce its own hash check here."
  Firmware validates Arch's UKI against the already-enrolled db key, so
  **nothing needs updating when Arch's kernel changes.**
- **Either drive can be pulled** — each OS keeps its own ESP and NVRAM entry.
- **Real chain of trust, not cosmetic.** Under Secure Boot, Limine forces
  `hash_mismatch_panic`, requires a hash on every file path, and disables the
  editor. The installer BLAKE2b-hashes every kernel/initrd into `limine.conf`,
  enrolls that config's hash into the binary, then signs with sbctl.

Local facts already gathered (2026-07-31):

- **Arch ESP PARTUUID: `b57468df-5404-499b-b84e-5b8ea0108ce6`** (`nvme0n1p1`,
  1 G vfat, label `EFI`). Prefer PARTUUID over `fslabel(EFI)` — a FAT label
  named `EFI` is collision-prone.
- **`/var/lib/sbctl` exists** (dated 2026-01-28), i.e. the modern sbctl layout.
  Both `limine.secureBoot` and `lanzaboote.pkiBundle` consume exactly
  `keys/db/db.pem` + `keys/db/db.key` from there.

### 🚨 Never do these — they break Arch's boot

- **Do not run `sbctl create-keys`, `sbctl setup`, or `sbctl enroll-keys`, and
  keep `secureBoot.autoGenerateKeys = false`.** Any of these mints a new
  PK/KEK/db; the moment it replaces the old db in firmware, **Arch's UKI is no
  longer trusted and Arch stops booting.** Copy the existing bundle instead.
- **Do not clear Secure Boot / "Erase all Secure Boot Settings" in the Framework
  firmware.** That's the standard lanzaboote/Limine first-run instruction and it
  does not apply here — the keys are already enrolled. It also drops the dbx.

### Remaining install-time steps

- [x] **Set the login password before first reboot.** ⚠️ Skipping this is a
      lockout — SDDM is the only entry point and SSH is key-only.
      `mutableUsers = true`, so the password persists in `/etc/shadow` across
      rebuilds; a *reinstall* needs this step again. Done 2026-08-02 for both
      `stef` and `root` (`passwd -S` reports `P` for each).

      The invocation in the obvious form does **not** work:
      `nixos-enter --root /mnt -- passwd stef` fails with
      `chroot: failed to run command 'passwd'`, and `-c 'passwd stef'` fails
      with `command not found`. `--` execs straight through `chroot`, and
      `-c` runs the target's bash but *both* inherit the host's `PATH`, which
      is all Arch paths that don't exist inside the chroot. Use an absolute
      path: `nixos-enter --root /mnt -c
      '/nix/var/nix/profiles/system/sw/bin/passwd stef'`. Not
      `/run/current-system/...` — `nixos-enter` mounts a tmpfs on the
      target's `/run`.
- [x] Arch's UKI filenames — confirmed from two readable sources without root:
      `/etc/mkinitcpio.d/*.preset` declares
      `default_uki="/efi/EFI/Linux/arch-linux.efi"` and
      `fallback_uki=".../arch-linux-fallback.efi"`, and `/var/lib/sbctl/files.json`
      lists exactly those two as the signed files. Both are wired into
      `extraEntries` already.
- [x] Copy `/var/lib/sbctl` to the same path on NixOS, root-owned, mode 0700.
      Done 2026-08-02. **Ordering matters and this list had it wrong:** it must
      happen *before* `nixos-install`, not after. `limine-install.py:433` does
      `if secureBoot.enable and not autoGenerateKeys and not
      os.path.exists("/var/lib/sbctl"): sys.exit(1)`, and the bootloader
      installer runs chrooted into `/mnt`, so the path it checks is
      `/mnt/var/lib/sbctl`. Copying afterwards means the install dies at its
      last step. Confirmed working: `✓ Signed /boot/efi/limine/BOOTX64.EFI`.
- [x] Get `resume_offset` once: `btrfs inspect-internal map-swapfile -r
      /swap/swapfile` (**not** `filefrag`, which is wrong for btrfs), then
      hard-code it into `boot.kernelParams`. disko does not emit it —
      disko#651 is open. Recreating the swapfile changes the offset.
      Measured 2026-08-02: **533760**, pinned in `configuration.nix`. Read it
      before `nixos-install` rather than after first boot — the swapfile
      exists as soon as disko has run, so the value can be baked into the
      closure you install instead of costing a rebuild.
- [ ] Boot-test the `uuid()` chainload path syntax — it's per Limine's
      CONFIG.md, but the nixpkgs example uses the `boot():///…` form and the
      `uuid()` chainload was not exercised in research.
- [ ] Do one real hibernate/resume test. `zramSwap` is on at 50%; NixOS excludes
      `/dev/zram*` from resume devices and `resume=` is explicit, so the image
      should go to the disk swapfile — but that's inferred, not verified.

### Accepted risks

- **`fwupd` capsule updates may silently no-op** — nixpkgs#534574 (open, filed
  2026-06-23) and lanzaboote#591, *"fwupd no longer respects
  `FWUPD_EFIAPPDIR`"* (open, 2026-04-22).

  Not a Limine defect, and **not** "fwupd + Secure Boot is broken" — an earlier
  draft of this file overstated it. The Limine module does the right thing
  (`limine.nix:488-512`): it signs fwupd's EFI helper with the sbctl keys
  (`sbctl sign -o /run/fwupd-efi/fwupdx64.efi.signed`), sets
  `FWUPD_EFIAPPDIR = "/run/fwupd-efi"`, and sets
  `services.fwupd.uefiCapsuleSettings.DisableShimForSecureBoot = true`. The bug
  is upstream fwupd ignoring that variable and looking for the `.signed` file
  beside the binary in the read-only nix store, where it can never exist.

  Symptom: `fwupdmgr update` reports success, reboot applies nothing. **Silent
  no-op — that's the hazard, not a crash.** It does not reproduce universally:
  two commenters report it working, and the reporter's own signing unit logs
  `✓ Signed /run/fwupd-efi/fwupdx64.efi.signed` — only the lookup fails.

  Decision: **keep `services.fwupd`.** Disabling it fixes nothing and removes a
  feature that may work. Verify once after install (note the version from
  `fwupdmgr get-devices`, update, reboot, check it changed); if it no-ops, fall
  back to Framework's EFI updater from a FAT32 USB for firmware only.

  ⚠️ The signing unit has `ConditionPathIsDirectory = "/var/lib/sbctl"`, so
  **fwupd signing silently skips if the sbctl keys haven't been copied over** —
  that install step is load-bearing for more than the bootloader.

  Separately: Framework has a documented case of an fwupd-delivered dbx update
  breaking owner-controlled Secure Boot, which is worth knowing before applying
  firmware updates on a machine with custom keys enrolled.
- The Limine module is young and has real issue traffic (mostly cosmetic).
- NixOS kernels are hash-pinned rather than Authenticode-signed — sound, but
  non-standard.
- No systemd-stub PCR11 measurement path, so TPM-sealed LUKS via
  `systemd-cryptenroll` the lanzaboote way isn't available. Not a stated
  requirement.
- Under Secure Boot the editor is disabled and the cmdline is inside a signed
  artifact, so a wrong `resume_offset` can't be fixed from the boot menu —
  recovery is booting an older generation.

### Rejected alternatives

| Option | Why not |
|---|---|
| Lanzaboote + one **shared** ESP | Works, and is the most standard chain (everything Authenticode-verified, plus a TPM/measured-boot future). But: third-party flake input tracking unstable; NixOS generations squeezed onto Arch's 1 G ESP (~85 MB per kernel+initrd); **NixOS cannot boot at all if drive 1 is removed**; and lanzaboote overwrites `EFI/BOOT/BOOTX64.EFI` + `loader/loader.conf`, which Arch may rely on. |
| Lanzaboote + EDK2 UEFI Shell chainload | `boot.loader.systemd-boot.windows.<n>.efiDeviceHandle` does this trick, but lanzaboote honours neither `windows` nor `extraEntries`, so the shell must be hand-signed and the `.conf` hand-written. Puts a full signed UEFI shell in the trust path, and `efiDeviceHandle` changes if drives are added. |
| rEFInd | `boot.loader.refind` is real and declarative, but has **zero** Secure Boot integration (unlike its Limine sibling from the same release). Signing means `sbctl sign` by hand after every bump. Upstream is one maintainer, last release 0.14.2 (April 2024), self-described beta. Also can't read LUKS. Strictly worse than Limine. |
| GRUB + os-prober | **No Secure Boot signing option exists** in `boot.loader.grub` on any current branch. Signed GRUB reading an unsigned `grub.cfg` is BootHole (CVE-2020-10713). `os-prober` has been off by default since GRUB 2.06 for security reasons. |

### Supporting facts (primary sources, 2026-07-31)

  **sd-boot cannot reference another partition, let alone another disk.** The
  Boot Loader Specification lists this as an explicit *non-goal*: "Referencing
  kernels or initrds on other partitions other than the partition containing
  the Type #1 boot loader entry. This is by design." Type #1 keys (`linux`,
  `initrd`, `efi`) are always "relative to the root directory of the partition
  they are referenced from". So a hand-written `.conf` pointing at Arch's ESP
  is not a supported thing — this is a wall, not an obstacle.

  **XBOOTLDR can't bridge the two drives either** — spec: "This partition must
  be located on the same disk as the ESP."

  **`bootctl --esp-path` / `--boot-path` don't help.** They're install-time
  flags for the userspace tool, not runtime multi-ESP scanning by sd-boot.

  **GRUB on NixOS has no Secure Boot path at all.** `boot.loader.grub`'s only
  signing support is GPG detached signatures for GRUB's own `verify` module —
  unrelated to UEFI Secure Boot. No shim plumbing, no options. So GRUB +
  `useOSProber` buys the unified menu at the cost of Secure Boot entirely.

  **rEFInd is now a real nixpkgs module** — `boot.loader.refind`, merged
  2025-06-06, generation-aware. The NixOS wiki page claiming rEFInd can't boot
  NixOS is stale. But the module has *zero* Secure Boot plumbing; upstream's
  story is shim + MOK enrollment, fully manual on top of it.

  **Lanzaboote is systemd-boot-only** (forces
  `boot.loader.systemd-boot.enable = mkForce false`), external flake input (the
  in-tree `lanzaboote-tool` was removed from nixpkgs 2025-07-23), v1.1.0 dated
  2026-06-22 and actively maintained — but still self-describes as having
  "sharp edges… cases where you end up with a system that does not boot".
  **Limine** (`boot.loader.limine`) is a second in-tree Secure Boot path worth
  evaluating.

  ✅ **The good news — Arch's keys are directly reusable.** Lanzaboote's
  `pkiBundle` expects exactly sbctl's on-disk layout
  (`${pkiBundle}/keys/db/db.pem` and `.../db.key`); sbctl stores plain
  unencrypted RSA-4096 + X.509 PEM pairs under `/var/lib/sbctl/keys/{PK,KEK,db}`
  and ships `import-keys --directory` / `export-enrolled-keys`. Supplying your
  own keys is lanzaboote's *documented primary flow*, not an edge case. **So the
  UEFI db does not need re-enrolling and Arch's signed UKI keeps working** —
  copy the key directory to where `pkiBundle` points. (Caveat: TPM-backed sbctl
  keys would not be portable as files; the default `file` keytype is.)

  Lanzaboote is also genuinely dual-boot-aware: `lzbt` garbage-collects
  `EFI/nixos` fully but filters `EFI/Linux` to files prefixed `nixos-`, with the
  source comment "The esp/EFI/Linux directory is assumed to be potentially
  shared with other distros" — so a shared ESP would not eat Arch's UKI. That
  makes the shared-ESP option viable, just not the best one.

---

## Deferred

- [ ] **The workstation has no backup story.** Verified 2026-08-01: `restic`
      appears nowhere in `hosts/workstation/configuration.nix`; only
      `hosts/main` runs `services.restic.backups`. There is also **no snapshot
      tooling anywhere in the repo** — no snapper, no btrbk, only
      `services.btrfs.autoScrub`.

      Indirect coverage that does exist: anything in Seafile syncs to main →
      `/mnt/data/seafile` → the `seafile-data` restic job → Pi, with version
      history. Dotfiles are in git. **Not covered:** local work not pushed,
      `~/Downloads`, VM images, Proton prefixes, and game saves outside Steam
      Cloud.

      ⚠️ Design tension to settle before extending restic here: CLAUDE.md's
      stated posture is "restic password only lives on `homeserver`; a
      compromise of the Pi cannot decrypt backups." A laptop that travels
      holding that password erodes that deliberately-chosen property. Options:
      (1) lean on Seafile and treat the laptop as disposable — no new secrets,
      fits the existing design; (2) a **separate** repo + separate password for
      a workstation job, so laptop compromise doesn't expose main's backups;
      (3) same repo, shared password — simplest and the one that actually
      weakens the model.
- [x] **`@games` and `@log` added** (2026-08-01). btrfs snapshots don't recurse
      into nested subvolumes, so these boundaries are how data gets marked
      never-snapshot/never-backup — carved out now because converting a
      populated directory later means moving every byte.

      - `@games` → `/home/stef/Games`, **`compress=no`** (game data is already
        compressed; `zstd:3` would spend write CPU for ~nothing). Operator chose
        the in-home path over a top-level `/games`.
      - `@log` → `/var/log`, compression kept (journals are text and compress
        well), so a root rollback doesn't discard the logs explaining it.

      Two ownership/boot details verified in nixpkgs source rather than assumed:

      1. **Nesting `@games` inside `@home` is safe.** systemd creates missing
         mount points as root, so `/home/stef` exists before the user does —
         but `update-users-groups.pl:235-239` runs `chown`/`chmod`
         *outside* the `if ! -e` guard, so NixOS fixes home ownership on every
         activation regardless.
      2. **The `@games` subvolume root is still root-owned**, and NixOS does not
         fix nested mounts — so `systemd.tmpfiles.rules` carries
         `d /home/stef/Games 0755 stef users -` or Steam can't write to it.
      3. **`/var/log` needs no `neededForBoot`** — it's already in
         `utils.pathsNeededForBoot` (with `/`, `/nix`, `/nix/store`, `/var`,
         `/var/lib`), and `fsNeededForBoot` checks that list. This also retires
         the caveat previously noted against `@nix`.

         Confirmed empirically, and it's a trap for a future reader:
         `fileSystems."/var/log".neededForBoot` evaluates to **`false`**, yet
         the generated mount options still include `x-initrd.mount`. The
         *option* is false; the *behaviour* is correct, because
         `fsNeededForBoot` ORs the option against the path list. Don't "fix"
         the false-looking option.

- [ ] **Still unconverted: `@nix` and `@docker`.** Deliberately left out — they
      buy nothing until snapshot tooling exists, and adding structure that does
      nothing is worse than not having it. Revisit together with the snapshot
      decision below.
- [ ] **No snapshot tooling in the repo** — no snapper, no btrbk, only
      `services.btrfs.autoScrub`. Until that changes, the subvolume splits above
      are pre-positioning plus the compression win on games; the
      rollback-protection rationale is unrealised.
- [ ] **Autostart the remaining resident user-session daemons.** The polkit
      agent is now wired in `configuration.nix`, but nothing starts
      `blueman-applet` or `hyprpaper` — the modules install them without
      autostarting, and there's no home-manager here. Each needs a Hyprland
      `exec-once` or a `systemd.user.services` unit. Note `blueman-manager`
      alone can pair but reliably fails to *connect* without `blueman-applet`
      resident as the BlueZ agent, so on-demand launch isn't sufficient there.
      Belongs with the dotfiles session.
- [ ] **`security.pam.services.polkit-1.fprintAuth = true`** — needed for
      fingerprint-backed polkit prompts, and agent-agnostic (it inserts
      `pam_fprintd.so` into the `polkit-1` PAM stack regardless of GUI). Not
      added yet because it's part of the deferred auth/PAM work above.
- [ ] **Dotfiles** (separate session). `.zshrc` hard-sources three Arch paths
      (`/usr/share/zsh/plugins/{fzf-tab,zsh-autosuggestions,zsh-syntax-highlighting}`).
      Since Arch keeps running, this needs conditional sourcing, not a path
      swap. Also: the Hyprland README documents Arch PAM edits for fingerprint
      auth (sudo/TTY/hyprlock) which become declarative
      `security.pam.services.*.fprintAuth` on NixOS, and fingerprints must be
      re-enrolled (`/var/lib/fprintd` is per-install).
- [ ] **`site` flake path input.** `/etc/nixos/site.nix` doesn't exist here.
      **Verified empirically 2026-07-31** with a minimal throwaway flake: an
      output that never references the input still fails with
      `while updating the flake input 'site'` → `opening file
      "/etc/nixos/site.nix": No such file or directory`. Inputs are fetched
      eagerly, so `.#workstation` is genuinely blocked by this despite
      workstation never reading `siteConfig`. Confirmed workaround for
      verification only: `nix eval --override-input site path:/path/to/stub.nix`.
      Still to decide: whether the NixOS workstation materialises the real file
      via `environment.etc` like main does, or whether `site` should stop being
      a flake-level input so unrelated hosts don't depend on it.
- [x] **Password / lockout.** Resolved 2026-08-02: `users.mutableUsers = true`
      made explicit in `configuration.nix`, password set imperatively at
      install (see the install-time step above). Chosen over an
      operator-managed hash file (moves the lockout, doesn't remove it) and
      agenix `hashedPasswordFile` + `neededForUsers` (gated on the keys work;
      revisit there if a declarative password is ever wanted). Committing a
      hash to git was rejected outright — offline-crackable and permanent in
      history. `security.sudo` remains default (wheel + password), which is
      fine.
- [ ] **Keys.** `keys/operator.pub` is different key material from
      `~/.ssh/id_ed25519.pub`, and it's both `stef`'s `authorized_keys` and an
      agenix recipient for all four secrets. Since NixOS is taking over the
      operator role, the private key has to land there and the agenix
      recipients need revisiting.

      Private key copied onto the NixOS side 2026-08-02 (operator-managed
      path, deliberately not recorded here). **Still blocking agenix:**
      `/etc/nixos/main-host-key.pub` doesn't exist on this machine, and
      `secrets/secrets.nix:22` reads it to build the recipient list — so
      every `agenix` operation fails to evaluate, including `-d`. Raw
      `age -d -i <key> secrets/<name>.age` works regardless, and was used to
      verify the operator key really is a recipient. Fetch the pubkey from
      main to unblock: `ssh operator@homeserver 'cat
      /etc/ssh/ssh_host_ed25519_key.pub'`.
- [x] **Address the new drive by `/dev/disk/by-id/`.** ✅ Done 2026-08-01 —
      and it turned out to be not merely prudent but **necessary**.

      🚨 **Inserting the new drive renumbered the existing one.** Before:
      Arch was `nvme0n1`. After: Arch is **`nvme1n1`** — the exact device
      `disko.nix` had hardcoded — and the new Kingston came up as `nvme0n1`.
      Running disko against the old config at that point would have wiped the
      work install.

      | Drive | by-id | Kernel name | Role |
      |---|---|---|---|
      | WD_BLACK SN850X 1000GB | `nvme-WD_BLACK_SN850X_1000GB_244254803786` | `nvme1n1` (was `nvme0n1`) | **Arch — do not touch** |
      | Kingston SNV3SM32T0 2 TB | `nvme-KINGSTON_SNV3SM32T0_50026B7283C08359` | `nvme0n1` | NixOS target (empty) |

      `disko.nix` now uses
      `/dev/disk/by-id/nvme-KINGSTON_SNV3SM32T0_50026B7283C08359` and the disko
      attribute is `disk.nixos` rather than `disk.nvme1n1`. **Never reintroduce
      a `/dev/nvmeXn1` path in this file.**

      Also confirmed: the Arch ESP PARTUUID
      (`b57468df-5404-499b-b84e-5b8ea0108ce6`) is unchanged by the renumbering,
      so the Limine chainload entries are still correct — a second vindication
      of addressing by PARTUUID rather than device path.

      Note the new drive is **2 TB**, not the ~1 TB originally assumed; the 2 G
      ESP and 40 G swapfile are unchanged, the btrfs partition takes the rest.

      **Verified at the script level, not just in config.** Built
      `config.system.build.diskoScript` and grepped it: 23 references to the
      Kingston by-id path, **zero** references to `nvme0n1`, `nvme1n1`, or
      `WD_BLACK`. The formatting script cannot touch the Arch drive. (Worth
      noting the system derivation hash is unchanged by the by-id switch — the
      device path lives only in disko's scripts, never in the system closure,
      so eval alone would not have caught a wrong device.)
- [ ] **Repo plumbing** (explicitly not now): no workstation install section in
      DEPLOY.md — you can't nixos-anywhere onto your own running machine, so the
      path is nix-on-Arch → `disko` → `nixos-install --flake .#workstation`,
      structurally like the Pi flash in §4.1. Also missing:
      `hosts/workstation/README.md`, workstation in the `flake.nix` description,
      CLAUDE.md's stale `/dev/nvme1n1` + dual-boot paragraph,
      `modules/alerts.nix` import for smartd, `nix.settings.trusted-users`,
      and an explicit comment on why there's no `system.autoUpgrade`.
- [ ] **DEPLOY.md §2.1 omits enabling flakes.** It covers `nix-daemon` and
      `extra-platforms = aarch64-linux` but never sets
      `experimental-features = nix-command flakes`, so following the playbook
      verbatim leaves you unable to evaluate this flake at all. Found the hard
      way on 2026-07-31: Arch's `nix` package ships a nix.conf containing only
      `build-users-group`.

---

## Parity gaps deliberately left out of batch 1

Present on Arch, not requested — listed so they're a choice and not an
oversight: `boot.binfmt.emulatedSystems = ["aarch64-linux"]` (**this repo's own
DEPLOY.md §4 flashes the Pi from here and needs it**), qemu, virtualbox,
embedded toolchains (`arm-none-eabi-gcc`, `aarch64-linux-gnu-gcc`, picocom,
jlink; the TI TMS570 and Vorago VA108xx toolchains are AUR-only and have no
nixpkgs equivalent), vscode, slack, libreoffice, inkscape, xournalpp, anydesk,
rpi-imager, btop, gdu, neovim, wireshark, nmap, tcpdump, socat, `gh`, glab,
gitleaks, ansible, bun, uv, ollama, wine + winetricks, doxygen,
cppcheck, and the font additions (`noto-fonts-cjk`, `font-awesome`, `inter`).
(`gamescope` was on this list until 2026-08-01 — now enabled via its module.)

Also noted: **dunst is being kept, but the dotfiles configure mako** — dunst
will start with no config until the dotfiles session addresses it.
