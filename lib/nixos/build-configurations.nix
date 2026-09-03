# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ self, lib, ... }:
let
  shared = import ./internal/shared.nix { inherit lib self; };
in
{
  /**
    Build a whole flake's `nixosConfigurations` AND `homeConfigurations`
    from ONE hosts attrset, in one call — the entry point most consuming
    flakes want.

    `buildNixosConfigurations` and the home half produce the
    two halves separately and are still available; this function is the
    two of them over a single shared plan. Prefer it, for two reasons
    beyond brevity:

    - The login bootstrap NEEDS both halves. A user in `loginHomes` has
      their home activated on first login from
      `<loginFlakeRef>#<user>@<host>`, so a flake that exports only
      `nixosConfigurations` fails at RUNTIME, on that user's first login,
      with "flake ... does not provide attribute homeConfigurations...".
      Producing both together removes the possibility.
    - One plan means one evaluation context. Calling both build functions
      by hand computes the expensive host-independent core twice from the
      same `_defaults` (Nix memoises `import <path>`, never its
      application), so a fleet pays for two full nixpkgs evaluations.

    Laziness makes producing both free: a flake output nobody forces is
    never evaluated, so a setup with no login users pays nothing for the
    `homeConfigurations` half.

    # Example

    ```nix
    # a complete flake outputs function:
    # extLib = inputs.nixpkgs-lib-extensions.lib
    outputs =
      { nixpkgs-lib-extensions, ... }@inputs:
      nixpkgs-lib-extensions.lib.buildConfigurations {
        _defaults = {
          inherit inputs;
          system = "x86_64-linux";
          loginHomes = [ "alice" ];
        };
        laptop = { };
        server = { users = [ ]; };
      };
    =>
    {
      nixosConfigurations = { laptop = <nixosSystem>; server = <nixosSystem>; };
      homeConfigurations = { alice = <homeManagerConfiguration>; };
    }
    ```

    # Type

    ```
    buildConfigurations ::
      { <hostname> = Attribute; }
      -> { nixosConfigurations = { <hostname> = NixosSystem; };
           homeConfigurations = { "<user>" | "<user>@<hostname>" = HomeManagerConfiguration; }; }
    ```

    # Arguments

    hosts
    : The same attrset `buildNixosConfigurations` accepts — same
    : allowlists, same `_defaults`/`_groups` semantics. See there for the
    : full key reference. (`buildHomeConfigurations` does NOT take this
    : shape: it is a flat argument set and rejects `_defaults`.)
  */
  buildConfigurations =
    hosts:
    let
      plan = shared.planHosts "buildConfigurations" hosts;
    in
    {
      nixosConfigurations = shared.systemsFromPlan "buildConfigurations" plan;
      homeConfigurations = shared.userHomesFromPlan "buildConfigurations" plan;
    };
}
