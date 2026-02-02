{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ...}:
  let

    myLib = import ./lib { inherit (nixpkgs) lib; };

    # Enable support on all linux platforms
    supportedSystems = nixpkgs.lib.platforms.linux;
    eachSupportedSystem = nixpkgs.lib.genAttrs supportedSystems;

  in {
    lib = myLib;

    # Helper for consumers
    extendLib = lib: nixpkgs.lib.recursiveUpdate lib myLib;

    # Keep overlay for pkgs.lib (works in some contexts)
    overlays.default = final: prev: {
      lib = prev.lib.recursiveUpdate prev.lib myLib;
    };


    packages = eachSupportedSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        gen-docs = ( pkgs.writeShellApplication {
          name = "notes";
          bashOptions = [ "errexit" "nounset" ];
          runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.nixdoc ];
          text = /* bash */ ''
            set -x

            function de_dub_sec_func_lib {
              awk '!/^# [^{]+{#sec-functions-library[^}]+}/ || !a[$0]++'
            }

            find lib -iname "*.nix" -type f  | sort -V | while read -r nix_file; do
              [[ "$nix_file" == "lib/default.nix" ]] && continue

              folder_name="$(basename "$(dirname "$nix_file")")"
              nixdoc --category "$folder_name" \
                     --description "$folder_name" \
                     --anchor-prefix "" \
                     --file "$nix_file"

            done | de_dub_sec_func_lib > docs/lib.md
          '';
        });
      }
    );
  };
}

# Test:
# nix repl --impure --expr '(builtins.getFlake (toString ./.)).outputs'
# nix repl --impure --expr '(import <nixpkgs> { overlays = [(builtins.getFlake (toString ./.)).overlays.default]; }).lib'

