# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ self, lib, ... }:
let
  shared = import ./internal/shared.nix { inherit lib self; };
in
{
  /**
    Build the home-manager configurations of every user in the `users/`
    tree, in one call: a FLAT argument set (no `hosts` attrset, no
    `_defaults`), keyed by user.

    Two shapes of key come out, and a user can produce both:

    - `"<user>"` -- the host-less home, built from that user's own
      `users/<user>/` files. Usable on any machine, including one this
      flake has never heard of.
    - `"<user>@<host>"` -- one per `users/<user>/hosts/<host>/` override
      directory, that home with the override merged on top.

    Every user with a `home.nix` gets an output; `loginHomes` does not
    gate this (it selects which homes a NixOS system leaves to the login
    bootstrap instead of building in, which is a `mkNixosSystem`
    concern). Outputs are lazy, so ones nobody builds cost nothing.

    This is the entry point for a home-manager-only flake. Because it has
    no declared host list, it discovers the host dimension from the tree
    alone -- so it emits `"<user>@<host>"` for EVERY override directory
    found, including hosts no NixOS system in your flake declares. Use
    `buildConfigurations` when you build systems too: it plans the hosts
    once and emits homes only for hosts that plan declares.

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
      Attribute -> { "<user>" | "<user>@<hostname>" = HomeManagerConfiguration; }
    ```

    # Arguments

    (arguments)
    : The same flat argument set `mkHomeConfiguration` takes. `username`
    : is rejected -- this builds every user in the tree, not one -- while
    : `hostname` is accepted and ignored, since each home's host comes
    : from the tree. In
    : practice: `inputs`, `system`, and any of `rootPath`/`loginFlakeRef`
    : (where to read the tree), `homeModules`, `specialArgs`, `overlays`,
    : `nixpkgsConfig`, `traceDiscoveredUsers`, ... -- validated against
    : the same allowlist, so a typo throws.
  */
  buildHomeConfigurations =
    args:
    # No plan: there is no hosts attrset to plan over. One flat argument
    # set means ONE context core, and the host dimension comes from the
    # tree (`users/<u>/hosts/<h>/`) rather than from declared hosts.
    shared.userHomesStandalone "buildHomeConfigurations" args;
}
