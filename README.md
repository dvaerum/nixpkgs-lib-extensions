# nixpkgs-lib-extensions

Extra functions not originally in `nixpkgs.lib` which I find useful.
Some I wrote myself and some I found on the internet.

**Documentation:**

- [docs/getting-started.md](docs/getting-started.md) — walkthrough of the
  NixOS/home-manager builders: concepts, recipes, gotchas
- [docs/lib.md](docs/lib.md) — generated API reference for every function

## The NixOS / home-manager builders

The main feature of this repo: build your `nixosConfigurations` and
standalone `homeConfigurations` from one per-user directory convention.
One `buildConfigurations` call produces both outputs from one hosts
attrset. See [docs/lib.md](docs/lib.md) for the full reference of
`buildConfigurations`, `buildNixosConfigurations`, `buildHomeConfigurations`,
`nixosConfigurationsBuilder`, `homeConfigurationsBuilder`,
`homeManagerBootstrapModule` and `normalUserModule`.

The quickest start is the flake template — a complete, working example
(it is evaluated by this repo's own `nix flake check`, so it cannot rot):

```
nix flake init -t github:dvaerum/nixpkgs-lib-extensions
```

Highlights:

- One `userRegistry` declares the users: each value is a
  directory with `home.nix` (home-manager config) and/or
  `configuration.nix` (NixOS config: account, groups, ...). Keys select
  hosts: `"alice@laptop"`, `"alice@*"` (every host), or plain `"alice"`.
- Each host's own config is found by convention:
  `hosts/<hostname>.nix` or `hosts/<hostname>/configuration.nix`.
- Arguments shared by every host go in one `_defaults` entry; host
  entries override per argument, and unknown keys throw instead of
  being silently ignored.
- User accounts are created automatically (`normalUserModule`). Homes
  are built into the system by default (home-manager NixOS module);
  users listed in `loginHomes` get theirs provisioned on first login
  instead, by a systemd user service.
- NixOS modules, overlays, home-manager modules and lib extensions
  exported by your flake inputs are wired in automatically; each
  input's own `lib` is namespaced as `lib.<inputName>`, and your
  flake's own `lib` output as `lib.flake`.

## What else is in here

- `declareZfsRootDisk` (disko): a complete ZFS root disk as one call —
  GPT partitions, pool, standard datasets plus one per user, optional
  encryption and extra datasets.
  [lib/disko/README.md](lib/disko/README.md) collects the operational
  notes that go with it, such as the hybrid-MBR step a Raspberry Pi 3
  bootrom needs after disko has formatted the disk.
- `importIfNix` / `importIfNixOr`: git-crypt-friendly imports. A
  `private.nix` that is an encrypted blob in the checkout (CI without
  the git-crypt key) evaluates to a default value with a warning
  instead of breaking evaluation.
- Small string/attrset helpers (`stringToTitle`, `recursiveMerge`, ...).

## Working on this repo

Two things are generated or enforced rather than hand-maintained, and
`nix flake check` fails when either has drifted. Nothing fixes them for
you, so run both before pushing:

```
nix fmt              # nixfmt the tree             (check: formatting)
nix run .#gen-docs   # rebuild docs/lib.md from    (check: docs-up-to-date)
                     # the doc comments in lib/
```

The full suite is `nix flake check`; three of its checks boot a VM and
need `/dev/kvm`.

## Use the extra library on its own

Three host examples for including the extra library in a NixOS config
without the builders.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixpkgs-lib-extensions = {
      url = "github:dvaerum/nixpkgs-lib-extensions";
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
