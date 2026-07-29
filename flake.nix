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
    # The script itself lives in scripts/gen-docs.sh;
    # writeShellApplication shellcheck-verifies it at build time.
    genDocsFor = system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      pkgs.writeShellApplication {
        name = "gen-docs";
        bashOptions = [ "errexit" "nounset" ];
        runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.nixdoc ];
        text = builtins.readFile ./scripts/gen-docs.sh;
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
      description = "Hosts + per-user directories built with buildNixosConfigurations / buildHomeConfigurations";
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
    # bootstrap-script, bootstrap-login-vm, bootstrap-system-homes-vm,
    # bootstrap-switch-vm
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

