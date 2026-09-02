# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
# Shared machinery lives in ./internal/shared.nix.
{ self, lib, ... }:
let
  shared = import ./internal/shared.nix { inherit lib self; };
in
{
  /**
    Build ONE user's standalone home-manager configuration for one host —
    the single-user primitive underneath `buildHomeConfigurations`, which
    calls it for every login-managed user of every host. Use it directly
    to export an individual home:

    ```nix
    homeConfigurations."alice@laptop" =
      extLib.mkHomeConfiguration {
        inherit inputs system;
        hostname = "laptop";
        username = "alice";
      };
    ```

    The user's `home.nix` files come from the users tree: their own
    `users/<user>/home.nix`, plus `users/<user>/hosts/<host>/home.nix`
    merged on top when a `hostname` is given and that directory exists.
    Companion `configuration.nix`
    files are ignored here — they are system configuration, imported by
    `mkNixosSystem`. Shares the package set, `specialArgs`
    and auto-collected home-manager modules with the other builders (it
    accepts the same shared options). The home-manager input is detected
    by capability (its `lib` exposes `homeManagerConfiguration`),
    regardless of the input's name.

    Throws when no home-manager input exists or the user has no matching
    `home.nix` on this host — a single requested home that cannot be
    built is an error, not an empty result.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.mkHomeConfiguration {
      inherit inputs;
      hostname = "laptop";
      system   = "x86_64-linux";
      username = "alice";
      # built from users/alice/home.nix, plus
      # users/alice/hosts/laptop/home.nix merged on top if it exists.
      # Omit `hostname` for the host-less home instead.
    }
    =>
    <homeManagerConfiguration for alice@laptop>
    ```

    # Type

    ```
    mkHomeConfiguration :: Attribute -> HomeManagerConfiguration
    ```

    # Arguments

    inputs
    : The flake's `inputs` set. The home-manager input is detected by capability.

    hostname
    : The host name the home is built for -- it selects the
    : `users/<username>/hosts/<hostname>/` override, when one exists.
    : OMIT it for the host-less home: no override applies and
    : `nixpkgsLibExtensions.hostname` is `null`.

    username
    : The user whose home to build.

    system
    : The system double, e.g. `"x86_64-linux"`.

    users
    : Accepted and IGNORED here, so one argument set can be shared with
    : `mkNixosSystem` (where it selects which of the tree a host takes).
    : This function builds the ONE user named by `username`, so there is
    : nothing to select. Users
    : are declared by DIRECTORIES under `users/` (read from `rootPath`,
    : default `inputs.self`, or from `loginFlakeRef`): this home is built
    : from `users/<username>/home.nix`, plus
    : `users/<username>/hosts/<hostname>/home.nix` merged on top when
    : `hostname` is given and that directory exists. Omitting `hostname`
    : builds the HOST-LESS home -- the user's own files alone, with no
    : `hosts/` override applying and `nixpkgsLibExtensions.hostname` set
    : to `null`.

    homeModules
    : home-manager modules added to the home configuration, on top of those
    : auto-collected from `inputs`. Default `[ ]`.

    The home configuration gets overridable (`mkDefault`) values for
    `home.username` (the user) and `home.homeDirectory` (`/home/<user>`).
    `home.stateVersion` gets a similar convenience default, but at a
    WEAKER priority than `mkDefault` -- so a consumer's own `mkDefault`
    pin in `home.nix` wins outright instead of colliding with the
    builder's default at equal priority -- and it tracks the CURRENT
    nixpkgs release, with a WARNING for any home actually relying on
    that moving default, naming the two pin recipes: the user's own
    `home.nix`, or fleet-wide via a shared `homeModules` entry.

    nixpkgs, group, specialArgs, tags, patches, nixpkgsConfig, overlays, allowedUnfreePackages, permittedInsecurePackages, rootPath, homeManager, inputContributions
    : Shared options (see `mkNixosSystem`).
  */
  # The long definition-list term above must stay on ONE line: gen-docs
  # recognizes a term by a one-line lookahead to the `:` marker, and a
  # wrapped term renders mangled (half prose, half bolded term).
  # See mkNixosSystem: validate here, delegate with no core.
  # `username` is this builder's own argument, hence the extra allowance.
  mkHomeConfiguration =
    args: shared.mkHome null (shared.validateBuilderArgs "mkHomeConfiguration" [ "username" ] args);
}
