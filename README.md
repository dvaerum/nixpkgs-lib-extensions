# Intro

Extra functions not originally in `nixpkgs.lib` which I find useful.
Some I wrote myself and some I found on the internet.

**Documentation:**

- [docs/getting-started.md](docs/getting-started.md) — walkthrough of the
  NixOS/home-manager builders: concepts, recipes, gotchas
- [docs/lib.md](docs/lib.md) — generated API reference for every function

# The NixOS / home-manager builders

The main feature of this repo: build your `nixosConfigurations` and
standalone `homeConfigurations` from one per-user directory convention.
See [docs/lib.md](docs/lib.md) for the full reference of
`buildNixosConfigurations`, `nixosConfigurationsBuilder`,
`homeConfigurationsBuilder`, `homeManagerBootstrapModule` and
`normalUserModule`.

The quickest start is the flake template — a complete, working example
(it is evaluated by this repo's own `nix flake check`, so it cannot rot):

```
nix flake init -t github:dvaerum/nixpkgs-lib-extensions
```

Highlights:

- One `homeConfigurations` registry declares the users: each value is a
  directory with `home.nix` (home-manager config) and/or
  `configuration.nix` (NixOS config: account, groups, ...). Keys select
  hosts: `"alice@laptop"`, `"alice@*"` (every host), or plain `"alice"`.
- Each host's own config is found by convention:
  `hosts/<hostname>.nix` or `hosts/<hostname>/configuration.nix`.
- User accounts are created automatically (`normalUserModule`), and a
  systemd user service provisions each user's home-manager profile on
  first login.
- NixOS modules, overlays and home-manager modules exported by your flake
  inputs are wired in automatically.

# Use the extra library on its own

Here are 3 different host examples for how to include the extra library
into a nixos config without the builders.

```
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixpkgs-lib-extensions = {
      url = "git+https://github.com/dvaerum/nixpkgs-lib-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixpkgs-lib-extensions, ... }:
  let
    system = "x86_64-linux";

  in {
    # Directly import into `lib` by merging them together
    nixosConfigurations.host_1 = nixpkgs.lib.nixosSystem {
      inherit system;

      lib = nixpkgs.lib.extend (final: prev:
        nixpkgs-lib-extensions.extendLib prev
      );

      modules = [
        ./configuration.nix
      ];
    };

    # Expose the extra library as `extLib` to the function args
    nixosConfigurations.host_2 = import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;

      specialArgs = {
        extLib = nixpkgs-lib-extensions.lib;
      };

      modules = [
        ./configuration.nix
      ];
    };

    # Same as for `host_1` just an example where `eval-config.nix` is used
    # instead of lib.nixosSystem
    nixosConfigurations.host_3 = import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;

      lib = nixpkgs.lib.extend (final: prev:
        nixpkgs-lib-extensions.extendLib prev
      );

      modules = [
        ./configuration.nix
      ];
    };
  };
}
```
