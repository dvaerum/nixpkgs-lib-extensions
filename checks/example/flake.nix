# Your NixOS + home-manager flake, built with nixpkgs-lib-extensions.
# Two hosts and a handful of users, wired by convention -- adjust hosts/
# and users/ and this becomes yours.
#
# Start here:
#   1. hosts/<yourhost>.nix   your machine's real config (the scaffolded
#                             ones are PLACEHOLDERS -- see below)
#   2. userRegistry           who exists, and on which hosts
#
# Layout convention: every registry value is a DIRECTORY containing
#   home.nix           the user's home-manager configuration
#   configuration.nix  NixOS config for that user (account, groups, ...)
# (either may be omitted; configuration.nix alone = system-only user).
#
# ---------------------------------------------------------------------
# Note for readers of the nixpkgs-lib-extensions repo itself: this
# directory is BOTH the `nix flake init` template and the fixture the
# test suite evaluates (checks/builders/default.nix calls this file's
# `outputs` with test inputs), which is why some concrete values here --
# direnv/git settings, group names -- are asserted by the checks. As a
# scaffolded user you can change or delete any of them freely.
# ---------------------------------------------------------------------
{
  description = "Example consumer of nixpkgs-lib-extensions' NixOS/home-manager builders";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-lib-extensions = {
      url = "github:dvaerum/nixpkgs-lib-extensions";
      # avoid locking a second nixpkgs/home-manager
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    { nixpkgs-lib-extensions, ... }@inputs:
    # `let` names exactly the values used by more than one builder call.
    let
      extLib = nixpkgs-lib-extensions.lib;
      # The default for every host below. A host on another architecture
      # overrides it in its own entry -- see `server`.
      system = "x86_64-linux";

      # One registry shared by all hosts. Key forms:
      #   "<user>@<host>"  that host only
      #   "<user>@*"       every host; MERGES with a matching "<user>@<host>"
      #   "<user>"         standalone default, only when NO @-entry matched
      #
      # REPLACE THESE WITH YOUR OWN before the first `nixos-rebuild switch`:
      # every key here becomes a REAL account on the host.
      userRegistry = {
        "alice" = ./users/alice; # plain default: applies (alice has no @-entries)
        "bob@laptop" = ./users/bob; # laptop only
        "carol@otherhost" = ./users/carol; # a host not in this flake: unused here
        "dave" = ./users/dave; # home.nix + configuration.nix (groups)
        "eve" = ./users/eve; # ONLY configuration.nix -> system-only user
        "frank@*" = ./users/frank-base; # on every host ...
        "frank@laptop" = ./users/frank-laptop; # ... plus laptop extras (merged)
        "grace@*" = ./users/grace-base; # on every host
      };

      # ONE host list feeds both builders below. The attribute keys are
      # the hostnames; each host's own configuration is found by
      # convention: ./hosts/<hostname>.nix (laptop) or
      # ./hosts/<hostname>/configuration.nix (server) -- `modules` is
      # only needed for anything beyond that.
      hosts = {
        # Arguments shared by every host. `_defaults` can never be a
        # hostname (a hostname cannot start with `_`). A host entry
        # overrides per argument -- and for "shared base plus per-host
        # extras" use the layered pairs: `modules`/`specialArgs` here,
        # `additionalModules`/`additionalSpecialArgs` on the host.
        _defaults = {
          inherit inputs system userRegistry;

          # An input that exports a CATALOG -- many nixosModules /
          # homeModules / overlays and no `default` -- cannot be
          # auto-imported, and evaluation THROWS until you say which
          # entries you want. Uncomment and adjust when you add one
          # (nixos-hardware and nixos-raspberrypi are the usual first
          # encounters). Keys must name inputs you actually have, so this
          # stays commented out here:
          #
          #   inputSpecialCases = {
          #     "nixos-hardware".nixosModules = null;             # none: import by hand below
          #     "nixos-raspberrypi".overlays = [ "bootloader" ];  # these, in this order
          #     "some-input".homeModules = "*";                   # all of them
          #   };
          # These users' home.nix activates on their FIRST LOGIN (via the
          # bootstrap and the homeConfigurations outputs below) instead of
          # with the system. Everyone else's home is built into the
          # system (home-manager NixOS module) and activates on
          # nixos-rebuild switch.
          loginUsers = [
            "alice"
            "bob"
          ];
          # Added to every user's home configuration on every host, both
          # mechanisms (asserted by the checks; adjust freely).
          homeSharedModules = [
            { programs.direnv.enable = true; }
          ];
        };

        # A host with users, home configurations and the login bootstrap.
        # Accounts for the registry users are created automatically:
        # `userModuleFn` defaults to `extLib.normalUserModule`. Pass your own
        # `username -> module` function for richer accounts, or `null` to
        # disable account creation.
        laptop = {
          # Per-host extras, layered ON TOP of the `_defaults` above rather
          # than replacing them -- that is what the `additional*` half of
          # each pair is for:
          #   additionalModules = [ ./modules/desktop.nix ];
          #   additionalSpecialArgs = { role = "workstation"; };
          # Everything else replaces the default outright, per argument:
          #   tags = [ "gpu" ];                      # also labels boot entries
          #   nixpkgsConfig = { cudaSupport = true; };
          #   allowedUnfreePackages = [ "steam" ];
          #   extraOverlays = [ (final: prev: { myPkg = prev.hello; }) ];
        };

        # A host without any user registry: no users, no bootstrap, no
        # homes -- the empty registry OVERRIDES the one from `_defaults`.
        server = {
          userRegistry = { };
          # A machine on another architecture overrides the default
          # `system` for itself alone:
          #   system = "aarch64-linux";
        };
      };
    in
    # ONE call, BOTH outputs: `nixosConfigurations` for the hosts, and the
    # "user@host" keyed `homeConfigurations` that the login bootstrap
    # activates for every `loginUsers` user. Exporting only the first is
    # the classic mistake -- it fails at that user's FIRST LOGIN, not at
    # build time -- so this entry point produces both from one plan.
    # (`buildNixosConfigurations` / `buildHomeConfigurations` still exist
    # if you ever want just one half.)
    extLib.buildConfigurations hosts;
}
