# nixpkgs-lib-extensions

A library for building a fleet of NixOS hosts and their home-manager
homes from one declarative description: a hosts attrset plus a `users/`
directory tree. It started as a handful of extra `nixpkgs.lib`
functions (some written here, some collected), and those helpers are
still included -- but the builders are what this repo is about now.

**Documentation:**

- [docs/getting-started.md](docs/getting-started.md) — walkthrough of the
  NixOS/home-manager builders: concepts, recipes, gotchas
- [docs/lib.md](docs/lib.md) — generated API reference for every function
- [docs/architecture.md](docs/architecture.md) — contributor notes: file
  layout and the plan -> core -> mkSystem/mkHome flow

## The NixOS / home-manager builders

Build your `nixosConfigurations` and standalone `homeConfigurations`
from one `users/` directory tree. One `buildConfigurations` call
produces both outputs from one hosts attrset. See
[docs/lib.md](docs/lib.md) for the full reference of
`buildConfigurations`, `buildNixosConfigurations`,
`buildHomeConfigurations`, `mkNixosSystem`, `mkHomeConfiguration`,
`homeManagerBootstrapModule` and `normalUserModule`.

The quickest start is the flake template — a complete, working example
(it is evaluated by this repo's own `nix flake check`, so it cannot rot):

```
nix flake init -t github:dvaerum/nixpkgs-lib-extensions
```

Highlights:

- A `users/` directory tree declares the users -- one directory each,
  with `home.nix` (home-manager config) and/or `configuration.nix`
  (NixOS config: account, groups, ...). A `users/<name>/hosts/<host>/`
  subdirectory holds the same two files for one host, merged on top
  there; a user with only `hosts/` subdirectories exists on those hosts
  alone. A host's `users` argument selects which of the tree get an
  account and a `"<user>@<host>"` home on it (omitted = all, `[ ]` =
  none); the tree's host-less `"<user>"` homes are unaffected either
  way.
- Home outputs are keyed by user: `homeConfigurations."alice"` (usable
  on any machine) and `"alice@laptop"` where she has a per-host
  override.
- Each host's own config is found by convention:
  `hosts/<hostname>.nix` or `hosts/<hostname>/configuration.nix`.
- Arguments shared by every host go in one `_defaults` entry; host
  entries override per argument, and unknown keys throw instead of
  being silently ignored. Exception: the users tree itself is
  discovered once from `_defaults` and shared by every host, so a
  host's own `rootPath`/`loginFlakeRef` cannot give it a different
  tree (see `buildNixosConfigurations`).
- User accounts are created automatically (`normalUserModule`). Homes
  are built into the system by default (home-manager NixOS module);
  users listed in `loginHomes` get theirs provisioned on first login
  instead, by a systemd user service.
- NixOS modules, overlays, home-manager modules and lib extensions
  exported by your flake inputs are wired in automatically; each
  input's own `lib` is namespaced as `lib.<inputName>`, and your
  flake's own `lib` output as `lib.flake`.

## Stability

The library is pre-1.0: breaking changes happen without compatibility
shims, and the documentation describes only the current API. Every
function is reachable both flat (`extLib.buildConfigurations`) and
namespaced (`extLib.nixos.buildConfigurations`); the **flat names are
the canonical surface** -- the docs and examples use them -- and the
namespaced duplicates exist for discoverability.

## What else is in here

- `declareZfsRootDisk` (disko): a complete ZFS root disk as one call —
  GPT partitions, pool, standard datasets plus one per user, optional
  encryption and extra datasets.
  [lib/disko/README.md](lib/disko/README.md) collects the operational
  notes that go with it, such as the hybrid-MBR case some bootroms
  need: the Raspberry Pi 3's bootrom only understands MBR partition
  tables, not the GPT this library uses, so a hybrid MBR overlays an
  MBR-compatible view of the firmware partition on top of the GPT disk.
  `legacyBoot = true` automates it; the README also documents the
  manual fallback.
- `importIfNix` / `importIfNixOr`: friendly to git-crypt (see
  `readIfPlainOr`'s doc comment, `docs/lib.md`, for what git-crypt
  does to a checkout without the decryption key). A `private.nix`
  that is an encrypted blob in the checkout (CI without the
  git-crypt key) evaluates to a default value with a warning instead
  of breaking evaluation.
- `readIfPlain` / `readIfPlainOr`: the same idea for a file that isn't
  Nix -- a plain secret or token. Reads it as a string when it's real
  plaintext, or returns a default (empty string, or your own) when
  it's still git-crypt ciphertext.
- `discoverPatches` / `discoverUserRegistry`: read a directory into
  something the builders consume -- a `patches` list from a `patches/`
  folder, or the users tree from a `users/` folder -- classifying each
  entry and warning about ones that look wrong.
- `detachedRun` / `interceptingWrapper` (`lib.systemd`): run a command
  in a transient `systemd-run --user` unit so it survives its own
  side effects. Built for `home-manager switch`, whose activation can
  restart the very unit the calling shell lives in.
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
    # Directly import into `lib` via the overlay -- the standard
    # `final: prev: delta` shape `lib.extend` composes, the same
    # form any other flake's overlay takes
    nixosConfigurations.host_1 = nixpkgs.lib.nixosSystem {
      inherit system;

      lib = nixpkgs.lib.extend
        nixpkgs-lib-extensions.libOverlays.default;

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

      lib = nixpkgs.lib.extend
        nixpkgs-lib-extensions.libOverlays.default;

      modules = [
        ./configuration.nix
      ];
    };
  };
}
```
