# This file is a function-file: the lib loader (lib/default.nix) applies it to
# `extLib` — the fully assembled nixpkgs-lib-extensions lib.
extLib:
let
  shared = import ./internal/shared.nix extLib;
in
{
  /**
    Build the standalone home-manager configurations of every host's
    LOGIN-managed users in one call: takes the SAME hosts attrset as
    `buildNixosConfigurations` (including `_defaults` and the allowlist
    validation), applies `homeConfigurationsBuilder` per login user, and
    merges everything into one `{ "<user>@<hostname>" = ...; }` set —
    assignable to a flake's `homeConfigurations` output directly.

    Only users listed in `loginUsers` (and shipping a `home.nix` for the
    host) get an output: system-managed homes are part of the systems
    built by `buildNixosConfigurations` and need no flake output. The
    produced set is exactly what the login bootstrap activates
    (`home-manager switch --flake <loginFlakeRef>#<user>@<host>`):

    ```nix
    let
      hosts = {
        _defaults = {
          inherit inputs system userRegistry;
          loginUsers = [ "alice" ];
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

    NixOS-only arguments in the attrset (`modules`, `userModuleFn`, ...)
    are accepted and ignored here, so one hosts attrset can feed both
    build functions (`homeSharedModules` applies on BOTH sides: to the
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
        loginUsers = [ "alice" ];
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
      # CONTEXT SHARING: same rule as in buildNixosConfigurations -- the
      # host-independent context core is computed ONCE from `_defaults`
      # and passed as `_core` to every home whose host entry overrides
      # none of the core arguments (shared.coreArgNames); otherwise the
      # host's homes get their own context from the merged arguments.
      defaultsCore = shared.mkContextCore split.defaults;
      coreArgSet = builtins.listToAttrs (
        map (n: {
          name = n;
          value = null;
        }) shared.coreArgNames
      );
      hostHomes =
        hostname:
        let
          entry = split.hostEntries.${hostname};
          merged = split.defaults // entry // { inherit hostname; };
          rawRegistry = merged.userRegistry or { };
          registry = if rawRegistry == null then { } else rawRegistry;
          loginUsers = merged.loginUsers or [ ];
          # login-managed users with an actual home.nix on this host
          usersHome = shared.loginUsersWithHome registry hostname loginUsers;
          coreAttr =
            if builtins.intersectAttrs coreArgSet entry == { } then { _core = defaultsCore; } else { };
        in
        # a host with no login-managed users (or no home-manager input)
        # simply contributes nothing
        if shared.detectHomeManager (merged.inputs or { }) == null then
          { }
        else
          builtins.listToAttrs (
            map (username: {
              name = "${username}@${hostname}";
              value = extLib.homeConfigurationsBuilder (merged // { inherit username; } // coreAttr);
            }) usersHome
          );
    in
    builtins.foldl' (acc: hostname: acc // hostHomes hostname) { } (
      builtins.attrNames split.hostEntries
    );
}
