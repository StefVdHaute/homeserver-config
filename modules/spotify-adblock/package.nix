# spotify-adblock — an LD_PRELOAD shim that wraps getaddrinfo and
# cef_urlrequest_create inside the Spotify client and drops every request
# outside its allowlist. nixpkgs does not carry it (NixOS/nixpkgs#209784), so
# it is built here from the upstream release tag — pure Rust, no native
# dependencies.
#
# Standalone on purpose, and exposed as a flake output, so nix-update can bump
# it against upstream's GitHub releases:
#
#   nix-update --flake spotify-adblock --version=stable
#
# That reads the releases feed, then rewrites version, hash and cargoHash
# below. Nothing else tracks this package — it is not a flake input, and
# `nix flake update` never touches it.
#
# Config lookup is $XDG_CONFIG_HOME/spotify-adblock/config.toml if that file
# exists, else /etc/spotify-adblock/config.toml. The crate is built with
# `panic = "abort"`, so a missing config aborts Spotify itself rather than
# degrading to no-op. Upstream's own list ships in share/spotify-adblock/ for
# hosts to plant as the /etc fallback.

{ lib
, rustPlatform
, fetchFromGitHub
}:

rustPlatform.buildRustPackage rec {
  pname = "spotify-adblock";
  version = "1.1.1";

  src = fetchFromGitHub {
    owner = "abba23";
    repo = "spotify-adblock";
    tag = "v${version}";
    hash = "sha256-R1xM/a+EzFd3I94EVCphbW+M114x6CtIeCOi9Fd9tpc=";
  };

  cargoHash = "sha256-gxGetdqaoJa/ZF1VnW6UXJyJfLBGZxZnyKpT/Qk/8Og=";

  postInstall = ''
    install -Dm444 config.toml $out/share/spotify-adblock/config.toml
  '';

  meta = {
    description = "LD_PRELOAD shim that blocks ads and tracking in the Spotify Linux client";
    homepage = "https://github.com/abba23/spotify-adblock";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
