# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ self, lib, ... }:
let
  shared = import ./internal/shared.nix { inherit lib self; };
in
{
  /**
    Build the standalone home-manager configurations of every host's
    LOGIN-managed users in one call: takes the SAME hosts attrset as
    `buildNixosConfigurations` (including `_defaults` and the allowlist
    validation), applies `mkHomeConfiguration` per login user, and
    merges everything into one `{ "<user>@<hostname>" = ...; }` set —
    assignable to a flake's `homeConfigurations` output directly.

    Only users listed in `loginHomes` (and shipping a `home.nix` for the
    host) get an output: SYSTEM-managed homes -- the default for anyone
    not in `loginHomes`, built into the NixOS system itself rather than
    activated at login; see `mkNixosSystem` for the full contrast -- are
    part of the systems built by `buildNixosConfigurations` and need no
    flake output. The
    produced set is exactly what the login bootstrap activates
    (`home-manager switch --flake <loginFlakeRef>#<user>@<host>`):

    ```nix
    let
      hosts = {
        _defaults = {
          inherit inputs system;
          loginHomes = [ "alice" ];
        };
        laptop = { };
        server = { users = [ ]; };
      };
    in
    {
      nixosConfigurations = extLib.buildNixosConfigurations hosts;
      homeConfigurations = extLib.buildHomeConfigurations hosts;
    }
    ```

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    # with users/alice/home.nix, users/frank/home.nix and
    # users/frank/hosts/laptop/home.nix on disk:
    extLib.buildHomeConfigurations {
      inherit inputs system;
    }
    =>
    { "alice"        = <homeManagerConfiguration>;   # usable anywhere
      "frank"        = <homeManagerConfiguration>;   # ditto
      "frank@laptop" = <homeManagerConfiguration>; } # + the laptop override
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
    args:
    # The user-centric entry point: no `hosts` attrset at all. Users come
    # from the `users/` tree under `rootPath` (or `loginFlakeRef`, when the
    # homes live in another flake), and the host dimension exists only
    # where a user has a `hosts/<host>` override directory. Implemented as
    # the degenerate one-host plan so it shares every code path (argument
    # validation, `_defaults` merge, ONE context core) with the fleet
    # entry points rather than duplicating them.
    shared.userHomesStandalone "buildHomeConfigurations" args;
}
