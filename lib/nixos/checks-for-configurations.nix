# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ lib, ... }:
{
  /**
    Turn built configurations into a flake `checks` output, so that
    "does the whole fleet still evaluate and build" is one command
    (`nix flake check`) rather than a habit.

    Takes what `buildConfigurations` returns and produces the per-system
    attrset a flake's `checks` expects. Both halves default to empty, so
    one alone is fine -- but the single-purpose builders return a BARE
    attrset keyed by name, so their output must be named
    (`{ inherit nixosConfigurations; }`), not passed straight in.

    Two things it does that a hand-written `mapAttrs` over
    `nixosConfigurations` reliably gets wrong:

    - **It buckets by each derivation's OWN system.** The obvious version
      writes `checks.x86_64-linux = mapAttrs ... nixosConfigurations;`,
      which files an aarch64 host's `toplevel` under the x86_64 name.
      Nothing catches that: `nix flake check` on an x86_64 machine then
      reports a check it cannot have run. The system is read from
      `drv.system`, which every derivation carries, so a mixed fleet
      lands in the right buckets without being told what they are.
    - **It knows the two halves build differently.** A host builds
      through `config.system.build.toplevel`, a home through
      `activationPackage`. That asymmetry is the other half of what gets
      copy-pasted wrong.

    Names are prefixed `nixos-` and `home-`, which also makes a
    collision impossible: two hosts or two homes cannot share a name
    (they are attrset keys), and a host can never collide with a home.

    Laziness still applies: a check nobody forces is never built, so
    adding this costs nothing until something asks for it.

    # Example

    ```nix
    # in a flake's outputs, alongside the configurations themselves
    let
      configurations = extLib.buildConfigurations {
        _defaults = {
          inherit inputs;
          system = "x86_64-linux";
        };
        laptop = { };
      };
    in
    configurations
    // {
      checks = extLib.checksForConfigurations configurations;
    }
    =>
    {
      checks.x86_64-linux = {
        nixos-laptop = <toplevel>;
        home-alice = <activationPackage>;
      };
    }
    ```

    # Type

    ```
    checksForConfigurations ::
      { nixosConfigurations = { <hostname> = NixosSystem; };
        homeConfigurations = { <name> = HomeManagerConfiguration; }; }
      -> { <system> = { "nixos-<hostname>" | "home-<name>" = Derivation; }; }
    ```

    # Arguments

    configurations
    : An attrset with `nixosConfigurations` and/or `homeConfigurations`.
    : Both default to `{ }`, so `buildConfigurations`' output can be
    : passed as-is and either half may be absent. The single-purpose
    : builders return a BARE attrset of configurations rather than one
    : under either key, so wrap theirs:
    : `checksForConfigurations { inherit nixosConfigurations; }`.
    : Passing such an output directly is not an error -- it simply
    : matches neither key and yields no checks at all.
  */
  checksForConfigurations =
    {
      nixosConfigurations ? { },
      homeConfigurations ? { },
      ...
    }:
    let
      entries =
        lib.mapAttrsToList (name: host: {
          name = "nixos-${name}";
          drv = host.config.system.build.toplevel;
        }) nixosConfigurations
        ++ lib.mapAttrsToList (name: home: {
          name = "home-${name}";
          drv = home.activationPackage;
        }) homeConfigurations;
    in
    lib.mapAttrs (_: group: lib.listToAttrs (map (e: lib.nameValuePair e.name e.drv) group)) (
      lib.groupBy (e: e.drv.system) entries
    );
}
