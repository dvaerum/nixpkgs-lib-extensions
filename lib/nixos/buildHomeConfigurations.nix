# This file is a function-file: the lib loader (lib/default.nix) applies it to
# `extLib` — the fully assembled nixpkgs-lib-extensions lib.
extLib:
let
  shared = import ./internal/shared.nix extLib;
in
{
  /**
    Build the standalone home-manager configurations for ALL hosts in one
    call: applies `homeConfigurationsBuilder` to every entry of the SAME
    hosts attrset `buildNixosConfigurations` takes (including `_defaults`
    and the allowlist validation) and merges the results into one
    `{ "<user>@<hostname>" = ...; }` set — assignable to a flake's
    `homeConfigurations` output directly.

    This produces exactly the outputs the login bootstrap activates
    (`home-manager switch --flake <flakeRef>#<user>@<host>`), for every
    host, from a single host list:

    ```nix
    let
      hosts = {
        _defaults = { inherit inputs system homeConfigurations; };
        laptop = { };
        server = { homeConfigurations = { }; };
      };
    in
    {
      nixosConfigurations = extLib.buildNixosConfigurations hosts;
      homeConfigurations = extLib.buildHomeConfigurations hosts;
    }
    ```

    NixOS-only arguments in the attrset (`modules`, `userModuleFn`, ...)
    are accepted and ignored here, just as the home-only
    `homeSharedModules` is ignored by `buildNixosConfigurations`. Key
    collisions between hosts are impossible: every produced key carries
    its own `@<hostname>` suffix.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.buildHomeConfigurations {
      _defaults = {
        inherit inputs system;
        homeConfigurations."alice" = ./users/alice;
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
    let
      split = shared.splitHostsArgs "buildHomeConfigurations" hosts;
    in
    builtins.foldl' (
      acc: hostname:
      acc
      // extLib.homeConfigurationsBuilder (
        split.defaults // split.hostEntries.${hostname} // { inherit hostname; }
      )
    ) { } (builtins.attrNames split.hostEntries);
}
