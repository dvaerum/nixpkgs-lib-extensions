{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Only used by the checks, to evaluate real home-manager configurations.
  inputs.home-manager = {
    url = "github:nix-community/home-manager";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ...}:
  let

    myLib = import ./lib { inherit (nixpkgs) lib; };

    # The platforms this lib is realistically used on. Keep the list short:
    # every entry multiplies the cost of `nix flake check --all-systems`
    # (each system evaluates nixpkgs and instantiates the example hosts).
    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    eachSupportedSystem = nixpkgs.lib.genAttrs supportedSystems;

    # Used both as the `gen-docs` package and by the docs-up-to-date check
    # (which runs this exact generator and diffs against docs/lib.md).
    genDocsFor = system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      pkgs.writeShellApplication {
        name = "gen-docs";
        bashOptions = [ "errexit" "nounset" ];
        runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.nixdoc ];
        text = /* bash */ ''
          set -x

          function de_dub_sec_func_lib {
            awk '!/^# [^{]+{#sec-functions-library[^}]+}/ || !a[$0]++'
          }

          # nixdoc emits definition lists ("term" line + ": ..." lines) which
          # only the NixOS manual toolchain understands; plain-markdown
          # viewers (GitHub included) render the colons literally. Convert
          # them to bulleted terms with indented descriptions instead.
          function def_lists_to_bullets {
            awk '
              /^```/ { fenced = !fenced }
              { lines[NR] = $0 }
              END {
                for (i = 1; i <= NR; i++) {
                  in_fence = 0
                  for (j = 1; j <= i; j++) if (lines[j] ~ /^```/) in_fence = !in_fence
                  if (lines[i] ~ /^```/) { print lines[i]; continue }
                  if (in_fence) { print lines[i]; continue }
                  if (i < NR && lines[i] != "" && lines[i] !~ /^: / && lines[i+1] ~ /^: /) {
                    print "- **" lines[i] "**"
                  } else if (lines[i] ~ /^: ?/) {
                    t = lines[i]; sub(/^: ?/, "", t); print "  " t
                  } else {
                    print lines[i]
                  }
                }
              }
            '
          }

          find lib -iname "*.nix" -type f  | sort -V | while read -r nix_file; do
            [[ "$nix_file" == "lib/default.nix" ]] && continue
            # internal helper files are not part of the public lib
            [[ "$nix_file" == */internal/* ]] && continue

            folder_name="$(basename "$(dirname "$nix_file")")"
            nixdoc --category "$folder_name" \
                   --description "$folder_name" \
                   --anchor-prefix "" \
                   --file "$nix_file"

          done | de_dub_sec_func_lib | def_lists_to_bullets > docs/lib.md
        '';
      };

  in {
    lib = myLib;

    # Helper for consumers
    extendLib = lib: nixpkgs.lib.recursiveUpdate lib myLib;

    # Keep overlay for pkgs.lib (works in some contexts)
    overlays.default = final: prev: {
      lib = prev.lib.recursiveUpdate prev.lib myLib;
    };


    # Scaffold the example into a new repo: `nix flake init -t <this flake>`.
    # The same files are evaluated by the checks, so the template cannot rot.
    templates.default = {
      path = ./checks/example;
      description = "Hosts + per-user directories built with nixosConfigurationsBuilder / homeConfigurationsBuilder";
    };

    checks = eachSupportedSystem (system: {
      builders = import ./checks/builders {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit nixpkgs home-manager myLib;
      };
      zfs-root-disk = import ./checks/zfs-root-disk.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit myLib;
      };
      lib-functions = import ./checks/lib-functions.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit nixpkgs myLib;
      };
      docs-up-to-date = import ./checks/docs-up-to-date.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit self;
        gen-docs = genDocsFor system;
      };
    }
    # bootstrap-script, bootstrap-login-vm, bootstrap-switch-vm
    // import ./checks/bootstrap {
      pkgs = nixpkgs.legacyPackages.${system};
      inherit nixpkgs home-manager myLib;
    });

    packages = eachSupportedSystem (system: {
      gen-docs = genDocsFor system;
    });
  };
}

# Test:
# nix repl --impure --expr '(builtins.getFlake (toString ./.)).outputs'
# nix repl --impure --expr '(import <nixpkgs> { overlays = [(builtins.getFlake (toString ./.)).overlays.default]; }).lib'

