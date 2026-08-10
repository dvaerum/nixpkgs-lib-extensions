{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Only used by the checks, to evaluate real home-manager configurations.
  inputs.home-manager = {
    url = "github:nix-community/home-manager";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }:
    let

      myLib = import ./lib { inherit (nixpkgs) lib; };
      # the module-level/flake-level split and its merge rule, shared with
      # the builders' own module lib (lib/nixos/internal/context.nix)
      moduleLevel = import ./lib/nixos/internal/module-level.nix {
        inherit (nixpkgs) lib;
        self = myLib;
      };

      # The collision decision is made against PRISTINE nixpkgs -- never
      # against the lib being extended. The overlay is applied to a lib that
      # may ALREADY hold these additions: the builders merge them in
      # themselves (lib/nixos/internal/context.nix) and then run every
      # input's lib contribution, this repo's included. Judging against the
      # accumulated lib made every name collide with its own earlier self and
      # get "skipped" with a warning naming nixpkgs for functions nixpkgs has
      # never defined.
      ownLibAdditions = moduleLevel.addOwnLib nixpkgs.lib myLib;

      # The canonical lib contribution: an OVERLAY (final: prev: delta), the
      # shape `lib.extend` composes and other flakes' overlays already use.
      # The delta covers exactly this repo's names; for a name `prev`
      # already holds, `recursiveUpdate ours theirs` lets the existing side
      # win at the leaves (an addition can never displace anything,
      # including a previous application of itself) while namespaces merge,
      # so `attrsets.recursiveMerge` survives alongside nixpkgs' own
      # attrsets. `final` is unused here, but the overlay form is what lets
      # OTHER flakes' additions reference each other through it.
      libOverlay =
        final: prev:
        nixpkgs.lib.recursiveUpdate ownLibAdditions (builtins.intersectAttrs ownLibAdditions prev);

      # The platforms this lib is realistically used on. Keep the list short:
      # every entry multiplies the cost of `nix flake check --all-systems`
      # (each system evaluates nixpkgs and instantiates the example hosts).
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSupportedSystem = nixpkgs.lib.genAttrs supportedSystems;

      # Used both as the `nix fmt` formatter and by the `formatting` check
      # (which runs this exact script with --check). One script, so the two can
      # never disagree about scope -- the same arrangement as gen-docs and
      # docs-up-to-date.
      fmtFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellApplication {
          name = "fmt";
          bashOptions = [
            "errexit"
            "nounset"
          ];
          runtimeInputs = [
            pkgs.findutils
            # `nixfmt` IS the RFC-style formatter now; nixfmt-rfc-style is a
            # deprecated alias for it and warns on evaluation.
            pkgs.nixfmt
          ];
          text = ''
            # checks/invalid-fixtures deliberately holds files that are NOT
            # valid Nix -- they feed the importIfNix* validity probes, and one
            # of them is a binary git-crypt blob -- so nixfmt must never see
            # them. Paths given as arguments are ignored on purpose: the scope
            # is always the whole tree minus those fixtures.
            nix_files() {
              find . -type f -name '*.nix' -not -path '*/invalid-fixtures/*' -print0
            }

            if [ "''${1:-}" = "--check" ]; then
              nix_files | xargs -0 nixfmt --check
            else
              nix_files | xargs -0 nixfmt
            fi
          '';
        };

      # Used both as the `gen-docs` package and by the docs-up-to-date check
      # (which runs this exact generator and diffs against docs/lib.md).
      # The script itself lives in scripts/gen-docs.sh;
      # writeShellApplication shellcheck-verifies it at build time.
      genDocsFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellApplication {
          name = "gen-docs";
          bashOptions = [
            "errexit"
            "nounset"
          ];
          runtimeInputs = [
            pkgs.coreutils
            pkgs.gawk
            pkgs.nixdoc
          ];
          text = builtins.readFile ./scripts/gen-docs.sh;
        };

    in
    {
      lib = myLib;

      # Helper for consumers: the lib contribution as an overlay
      # (final: prev: delta), composed with `lib.extend` like any other
      # input's. It carries only the module-level half, and can only ADD --
      # see lib/nixos/internal/module-level.nix: it feeds a consuming
      # flake's module `lib`, where the system builders have no meaning.
      libOverlays.default = libOverlay;

      # Keep overlay for pkgs.lib (works in some contexts)
      # ... and the same for pkgs.lib.
      overlays.default = final: prev: {
        lib = nixpkgs.lib.recursiveUpdate ownLibAdditions prev.lib;
      };

      # Scaffold the example into a new repo: `nix flake init -t <this flake>`.
      # The same files are evaluated by the checks, so the template cannot rot.
      templates.default = {
        path = ./checks/example;
        description = "Hosts + per-user directories built with buildConfigurations";
      };

      checks = eachSupportedSystem (
        system:
        {
          builders = import ./checks/builders {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit nixpkgs home-manager myLib;
          };
          zfs-root-disk = import ./checks/zfs-root-disk.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit myLib;
          };
          zfs-key-file = import ./checks/zfs-key-file.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit myLib;
          };
          # its own check: verifying `patches` is import-from-derivation
          # over the whole nixpkgs tree, which inside `builders` blocked
          # every cheap assertion there until the copy existed
          nixpkgs-patching = import ./checks/nixpkgs-patching.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit nixpkgs myLib;
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
          formatting = import ./checks/formatting.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit self;
            fmt = fmtFor system;
          };
        }
        # bootstrap-script, bootstrap-login-vm, bootstrap-system-homes-vm,
        # bootstrap-switch-vm
        // import ./checks/bootstrap {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit nixpkgs home-manager myLib;
        }
      );

      packages = eachSupportedSystem (system: {
        gen-docs = genDocsFor system;

        # An on-demand EXPERIMENT, not a check: it boots a VM with real ZFS
        # (kernel module, 2 GB) to answer "does ZFS strip a trailing newline
        # from a keyformat=passphrase key file?" -- and the answer is yes,
        # recorded in the file. The library was then deliberately made
        # independent of it: the invariant that matters, that all three key
        # writers agree byte for byte, is pinned cheaply by
        # checks/zfs-key-file.nix. Run it with
        # `nix build .#zfs-newline-probe` when touching that code.
        zfs-newline-probe = import ./checks/zfs-passphrase-newline.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };
      });

      # `nix fmt` -- the same script the `formatting` check runs with --check,
      # so fixing a failed check is always just `nix fmt`.
      formatter = eachSupportedSystem fmtFor;
    };
}

# Test:
# nix repl --impure --expr '(builtins.getFlake (toString ./.)).outputs'
# nix repl --impure --expr '(import <nixpkgs> { overlays = [(builtins.getFlake (toString ./.)).overlays.default]; }).lib'
