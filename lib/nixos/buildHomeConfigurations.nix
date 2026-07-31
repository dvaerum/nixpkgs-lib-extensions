# Loaded by lib/default.nix under the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
{ self, lib, ... }:
let
  shared = import ./internal/shared.nix { inherit lib self; };
in
{
  /**
    Build the standalone home-manager configurations of every host's
    LOGIN-managed users in one call: takes the SAME hosts attrset as
    `buildNixosConfigurations` (including `_defaults` and the allowlist
    validation), applies `homeConfigurationsBuilder` per login user, and
    merges everything into one `{ "<user>@<hostname>" = ...; }` set —
    assignable to a flake's `homeConfigurations` output directly.

    Only users listed in `loginHomes` (and shipping a `home.nix` for the
    host) get an output: system-managed homes are part of the systems
    built by `buildNixosConfigurations` and need no flake output. The
    produced set is exactly what the login bootstrap activates
    (`home-manager switch --flake <loginFlakeRef>#<user>@<host>`):

    ```nix
    let
      hosts = {
        _defaults = {
          inherit inputs system userRegistry;
          loginHomes = [ "alice" ];
        };
        laptop = { };
        server = { userRegistry = { }; };
      };
    in
    {
      nixosConfigurations = extLib.buildNixosConfigurations hosts;
      homeConfigurations = extLib.buildHomeConfigurations hosts;
    }
    ```

    NixOS-only arguments in the attrset (`modules`, `userModule`, ...)
    are accepted and ignored here, so one hosts attrset can feed both
    build functions (`homeModules` applies on BOTH sides: to the
    login homes built here and to the system-managed homes in
    `buildNixosConfigurations`). Key collisions between hosts are
    impossible: every produced key carries its own `@<hostname>` suffix.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.buildHomeConfigurations {
      _defaults = {
        inherit inputs system;
        userRegistry = {
          "alice" = ./users/alice;
          "bob"   = ./users/bob; # system-managed: no output
        };
        loginHomes = [ "alice" ];
      };
      laptop = { };
      desktop = { };
    }
    =>
    { "alice@laptop" = <homeManagerConfiguration>;
      "alice@desktop" = <homeManagerConfiguration>; }
    ```

    # Type

    ```
    buildHomeConfigurations ::
      { <hostname> = Attribute; } -> { "<user>@<hostname>" = HomeManagerConfiguration; }
    ```

    # Arguments

    hosts
    : The same attrset accepted by `buildNixosConfigurations` (same
    : allowlists, same `_defaults` semantics); see there for the full
    : key reference.
  */
  buildHomeConfigurations =
    hosts:
    # Built from a plan, exactly as buildNixosConfigurations is: one split,
    # one `_defaults` merge, one context core per host. Calling both
    # builders still plans twice -- `buildConfigurations` is the entry point
    # that plans ONCE and projects both outputs from it, and is what a flake
    # exporting nixosConfigurations and homeConfigurations should use.
    shared.homesFromPlan "buildHomeConfigurations" (shared.planHosts "buildHomeConfigurations" hosts);
}
