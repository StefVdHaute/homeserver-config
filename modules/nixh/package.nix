# nixh — a picker for the nix commands this repo actually needs.
#
# Proof of concept. The point is not to hide nix: every action is stored as a
# literal shell recipe, the picker previews that recipe, and running it evals
# the same text you just read. What you see is what runs, so the tool teaches
# itself out of a job — once you know a verb, `nixh <verb>` skips the picker.
#
# Kept separate from the module so it can be built (and shellchecked) on its
# own: `nix build -f package.nix` with a host argument.

{ lib
, writeShellApplication
, runCommand
, nh
, fzf
, git
, nix
, coreutils
, host
, flake ? "github:StefVdHaute/homeserver-config"
, repo ? "$HOME/repositories/homeserver-config"
}:

let
  # Each recipe is the literal command text for one verb. Placeholders in
  # <ANGLE_BRACKETS> are prompted for at run time. Multi-line recipes are
  # deliberate: `bump` is four commands, and pretending otherwise is how you
  # end up not knowing which step arms the fleet.
  recipes = {
    check = ''
      nh os build --diff always --refresh -H ${host} <FLAKE>
    '';

    switch = ''
      nh os switch --ask --diff always --refresh -H ${host} <FLAKE>
    '';

    boot = ''
      nh os boot --ask --diff always --refresh -H ${host} <FLAKE>
    '';

    bump = ''
      cd ${repo}
      nix flake update nixpkgs nixpkgs-unstable
      nix build --no-link --dry-run .#nixosConfigurations.main.config.system.build.toplevel
      nix build --no-link --dry-run .#nixosConfigurations.backup.config.system.build.toplevel
      nix build --no-link --dry-run .#nixosConfigurations.workstation.config.system.build.toplevel
    '';

    commit = ''
      git -C ${repo} commit -m "<MSG>" flake.lock
    '';

    push = ''
      git -C ${repo} push
    '';

    fleet = ''
      cd ${repo}
      nix build --no-link --dry-run .#nixosConfigurations.main.config.system.build.toplevel
      nix build --no-link --dry-run .#nixosConfigurations.backup.config.system.build.toplevel
    '';

    gens = ''
      sudo nixos-rebuild list-generations
    '';

    roll = ''
      sudo nixos-rebuild switch --rollback
    '';

    gc = ''
      nh clean all --ask --keep 10 --keep-since <AGE>
    '';

    find = ''
      nh search packages <TERM>
    '';
  };

  # Order is the order you meet them: look, act, move the fleet, then the
  # recovery and housekeeping tail.
  menu = [
    { verb = "check";  blurb = "What would change on this machine, without touching it"; }
    { verb = "switch"; blurb = "Upgrade this machine now and make it the boot default"; }
    { verb = "boot";   blurb = "Stage the upgrade for the next boot instead"; }
    { verb = "bump";   blurb = "Roll the flake inputs and verify all three hosts still build"; }
    { verb = "commit"; blurb = "Commit the rolled flake.lock"; }
    { verb = "push";   blurb = "Push — this is the step that arms the 04:30 fleet upgrade"; }
    { verb = "fleet";  blurb = "Will main and backup still evaluate? Check before you push"; }
    { verb = "gens";   blurb = "List system generations"; }
    { verb = "roll";   blurb = "Roll back to the previous generation"; }
    { verb = "gc";     blurb = "Delete old generations and dedupe the store"; }
    { verb = "find";   blurb = "Search nixpkgs for a package"; }
  ];

  # Left-aligned columns. fixedWidthString pads on the left, which would glue
  # the verb to its blurb and break fzf's {1} field along with it.
  padTo = width: s: s + lib.concatStrings (lib.genList (_: " ") (width - lib.stringLength s));

  # Menu and every recipe in ONE derivation. A store path per verb (linkFarm +
  # a writeText each) shows up as a separate line in every `nh` diff forever,
  # and each new verb adds another. The text rides in as build-time env vars
  # so no shell quoting or heredoc delimiter can be tripped by recipe content.
  #
  # The picker cats $RECIPES/<verb> for its preview and the runner reads the
  # same file — one source of truth for the command text.
  data = runCommand "nixh-data"
    (lib.mapAttrs' (verb: text: lib.nameValuePair "recipe_${verb}" text) recipes // {
      menuText = lib.concatMapStrings (e: "${padTo 8 e.verb}${e.blurb}\n") menu;
    })
    ''
      mkdir -p $out/recipes
      printf '%s' "$menuText" > $out/menu
      ${lib.concatStrings (lib.mapAttrsToList (verb: _: ''
        printf '%s' "$recipe_${verb}" > $out/recipes/${verb}
      '') recipes)}
    '';
in

writeShellApplication {
  name = "nixh";
  runtimeInputs = [ nh fzf git nix coreutils ];
  text = ''
    RECIPES=${data}/recipes
    MENU=${data}/menu
    FLAKE_DEFAULT=${lib.escapeShellArg flake}

    usage() {
      echo "nixh — pick a nix command, see it, run it."
      echo
      echo "  nixh                 open the picker"
      echo "  nixh <verb> [arg]    run a verb directly"
      echo "  nixh list            print every verb and its recipe"
      echo
      sed 's/^/  /' "$MENU"
    }

    # Fill the <PLACEHOLDER> tokens. Everything is prompted rather than
    # flagged: the picker is interactive by definition, and a prompt with a
    # visible default teaches the value a flag would have hidden.
    resolve() {
      local recipe="$1" arg="''${2-}" reply

      if [[ $recipe == *"<FLAKE>"* ]]; then
        reply=$arg
        [[ -n $reply ]] || read -r -p "flake [$FLAKE_DEFAULT]: " reply
        recipe=''${recipe//<FLAKE>/''${reply:-$FLAKE_DEFAULT}}
      fi

      if [[ $recipe == *"<TERM>"* ]]; then
        reply=$arg
        [[ -n $reply ]] || read -r -p "search term: " reply
        recipe=''${recipe//<TERM>/$reply}
      fi

      if [[ $recipe == *"<AGE>"* ]]; then
        reply=$arg
        [[ -n $reply ]] || read -r -p "keep everything newer than [30d]: " reply
        recipe=''${recipe//<AGE>/''${reply:-30d}}
      fi

      if [[ $recipe == *"<MSG>"* ]]; then
        reply=$arg
        [[ -n $reply ]] || read -r -p "commit message [$MSG_DEFAULT]: " reply
        recipe=''${recipe//<MSG>/''${reply:-$MSG_DEFAULT}}
      fi

      printf '%s' "$recipe"
    }

    run() {
      local verb="$1" arg="''${2-}" recipe

      if [[ ! -f $RECIPES/$verb ]]; then
        echo "nixh: no such verb: $verb" >&2
        usage >&2
        return 1
      fi

      recipe=$(resolve "$(cat "$RECIPES/$verb")" "$arg")

      # Show it before running it. This is the whole point of the tool.
      echo
      while IFS= read -r line; do
        printf '  $ %s\n' "$line"
      done <<< "$recipe"
      echo

      eval "$recipe"
    }

    MSG_DEFAULT="chore(flake): roll inputs"

    case "''${1-}" in
      -h | --help | help)
        usage
        ;;
      list)
        for path in "$RECIPES"/*; do
          echo "── ''${path##*/}"
          sed 's/^/   /' "$path"
        done
        ;;
      "")
        if selection=$(fzf --height=60% --reverse --border \
                           --prompt='nixh > ' \
                           --header='select a command — the preview is exactly what will run' \
                           --preview="cat $RECIPES/{1}" \
                           --preview-window='down,45%,border-top' \
                           < "$MENU"); then
          run "''${selection%% *}"
        fi
        ;;
      *)
        run "$1" "''${2-}"
        ;;
    esac
  '';
}
