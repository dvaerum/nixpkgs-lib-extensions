# Your NixOS + home-manager flake, built with nixpkgs-lib-extensions.
# Two hosts and a handful of users, wired by convention -- adjust hosts/
# and users/ and this becomes yours.
#
# Start here:
#   1. hosts/<yourhost>.nix   your machine's real config (the scaffolded
#                             ones are PLACEHOLDERS -- see below)
#   2. users/<name>/          who exists (one directory per user)
#
# Layout convention: every user is a DIRECTORY under ./users containing
#   home.nix           the user's home-manager configuration
#   configuration.nix  NixOS config for that user (account, groups, ...)
#   hosts/<host>/      the same two files, applied on that host only
# (any may be omitted; configuration.nix alone = system-only user, and a
# directory with only hosts/ = a user who exists only on those hosts).
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

      # Users are declared by the ./users tree -- one directory per user,
      # no registry attrset anywhere. REPLACE THESE WITH YOUR OWN before
      # the first `nixos-rebuild switch`: every directory here becomes a
      # REAL account on the host.
      #
      #   users/alice/home.nix                    on every host
      #   users/dave/{home,configuration}.nix     home + groups, every host
      #   users/eve/configuration.nix             system-only user (no home)
      #   users/grace/home.nix                    on every host
      #   users/frank/{home,configuration}.nix    on every host ...
      #   users/frank/hosts/laptop/configuration.nix   ... plus laptop extras (merged)
      #   users/bob/hosts/laptop/home.nix         laptop ONLY (no files of his own)
      #   users/carol/hosts/otherhost/home.nix    a host not in this flake: unused here

      # ONE host list feeds both builders below. The attribute keys are
      # the hostnames; each host's own configuration is found by
      # convention: ./hosts/<hostname>.nix (laptop) or
      # ./hosts/<hostname>/configuration.nix (server) -- `modules` is
      # only needed for anything beyond that.
      hosts = {
        # Arguments shared by every host. `_defaults` can never be a
        # hostname (a hostname cannot start with `_`). A host entry
        # overrides per argument -- and for "shared base plus per-host
        # extras" the host uses its `extra` slot: a bare key REPLACES what
        # is here, `extra.<key>` ADDS to it.
        _defaults = {
          inherit inputs system;

          # An input that exports a CATALOG -- many nixosModules /
          # homeModules / overlays and no `default` -- cannot be
          # auto-imported, and evaluation THROWS until you say which
          # entries you want. Uncomment and adjust when you add one
          # (nixos-hardware and nixos-raspberrypi are the usual first
          # encounters). Keys must name inputs you actually have, so this
          # stays commented out here:
          #
          #   inputContributions = {
          #     "nixos-hardware".nixosModules = null;             # none: import by hand below
          #     "nixos-raspberrypi".overlays = [ "bootloader" ];  # these, in this order
          #     "some-input".homeModules = "*";                   # all of them
          #   };
          # These users' home.nix activates on their FIRST LOGIN (via the
          # bootstrap and the homeConfigurations outputs below) instead of
          # with the system. Everyone else's home is built into the
          # system (home-manager NixOS module) and activates on
          # nixos-rebuild switch.
          loginHomes = [
            "alice"
            "bob"
          ];
          # Added to every user's home configuration on every host, both
          # mechanisms (asserted by the checks; adjust freely).
          homeModules = [
            { programs.direnv.enable = true; }
          ];
        };

        # A host with users, home configurations and the login bootstrap.
        # Accounts for the registry users are created automatically:
        # `userModule` defaults to `extLib.normalUserModule`. Pass your own
        # `username -> module` function for richer accounts, or `null` to
        # disable account creation.
        laptop = {
          # Per-host extras go in `extra`, layered ON TOP of `_defaults`
          # (lists concatenate, attrsets merge):
          #   extra.modules = [ ./modules/desktop.nix ];
          #   extra.specialArgs = { role = "workstation"; };
          #   extra.homeModules = [ ./home/desktop.nix ];
          # A bare key replaces the default outright instead:
          #   tags = [ "gpu" ];                      # also labels boot entries
          #   nixpkgsConfig = { cudaSupport = true; };
          #   allowedUnfreePackages = [ "steam" ];
          #   overlays = [ (final: prev: { myPkg = prev.hello; }) ];
          # With many similar hosts, shared per-kind arguments can live in
          # a reserved `_groups.<name>` entry (merged between `_defaults`
          # and the host), selected here with:
          #   group = "server";
        };

        # A host with none of the tree's users: no accounts, no bootstrap,
        # no homes. `users` selects which of the users/ tree apply here --
        # omitted means all of them, `[ ]` means none.
        server = {
          users = [ ];
          # A machine on another architecture overrides the default
          # `system` for itself alone:
          #   system = "aarch64-linux";
        };
      };
    in
    # ONE call, BOTH outputs: `nixosConfigurations` for the hosts, and the
    # "user@host" keyed `homeConfigurations` that the login bootstrap
    # activates for every `loginHomes` user. Exporting only the first is
    # the classic mistake -- it fails at that user's FIRST LOGIN, not at
    # build time -- so this entry point produces both from one plan.
    # (`buildNixosConfigurations` / `buildHomeConfigurations` still exist
    # if you ever want just one half.)
    extLib.buildConfigurations hosts;
}
