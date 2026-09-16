# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ lib, ... }:
{
  /**
    Turn built configurations into a flake `checks` output, so that
    "does the whole fleet still evaluate and build" is one command
    (`nix flake check`) rather than a habit.

    Takes what `buildConfigurations` returns and produces the per-system
    attrset a flake's `checks` expects. Both halves default to empty, so
    one alone is fine -- see the `configurations` argument for wrapping
    a single-purpose builder's bare output.

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
    : Passing such an output directly matches neither key and yields no
    : checks; because that leaves `checks` gating nothing while
    : `nix flake check` still passes, it WARNS (naming the stray keys)
    : rather than failing quietly. An empty result warns either way.
  */
  checksForConfigurations =
    args@{
      nixosConfigurations ? { },
      homeConfigurations ? { },
      ...
    }:
    let
      # Keys that are neither half. The `...` above accepts them silently,
      # which is exactly how a BARE builder output (keyed by hostname)
      # produces no checks at all -- so they are the evidence for the
      # warning below, not noise to ignore.
      strayKeys = lib.filter (k: k != "nixosConfigurations" && k != "homeConfigurations") (
        lib.attrNames args
      );

      entries =
        lib.mapAttrsToList (name: host: {
          name = "nixos-${name}";
          drv = host.config.system.build.toplevel;
        }) nixosConfigurations
        ++ lib.mapAttrsToList (name: home: {
          name = "home-${name}";
          drv = home.activationPackage;
        }) homeConfigurations;

      result = lib.mapAttrs (_: group: lib.listToAttrs (map (e: lib.nameValuePair e.name e.drv) group)) (
        lib.groupBy (e: e.drv.system) entries
      );
    in
    # An empty result is never what a caller wanted: `checks` then gates
    # NOTHING while `nix flake check` still reports success, so the gate
    # looks green precisely because it is doing no work. Warn rather than
    # throw -- a flake mid-migration with no configurations yet is a real
    # state, just not one to reach silently.
    if entries != [ ] then
      result
    else if strayKeys != [ ] then
      lib.warn "checksForConfigurations: nothing to check -- got ${lib.concatStringsSep ", " strayKeys} but neither `nixosConfigurations` nor `homeConfigurations`. The single-purpose builders return a BARE attrset keyed by name, so their output must be NAMED: `checksForConfigurations { inherit nixosConfigurations; }`, not passed straight in. As written, `checks` gates nothing and `nix flake check` still passes." result
    else
      lib.warn "checksForConfigurations: nothing to check -- both `nixosConfigurations` and `homeConfigurations` are empty, so `checks` gates nothing and `nix flake check` passes without building anything." result;
}
