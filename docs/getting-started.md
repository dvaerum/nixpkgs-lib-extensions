# Getting started with the NixOS / home-manager builders

This guide takes you from nothing to a NixOS host with provisioned
users, using the builders from this repo. The API reference for every
function lives in [lib.md](lib.md); this document explains the concepts
and the workflow.

## What you get

- One **registry** declares your users: who exists, on which hosts,
  what their home looks like, and their system-level config (groups,
  account settings).
- Each **host** is one attrset entry; its machine config is found by
  file convention.
- Login accounts are **created automatically**, each with a private
  primary group.
- On first login, a systemd user service runs `home-manager switch`
  for the user in the background -- no manual bootstrap.
- NixOS modules, home-manager modules, overlays and lib extensions
  exported by your flake inputs are **wired in automatically**.

## Quick start

Scaffold a working setup into an empty directory:

```
nix flake init -t github:dvaerum/nixpkgs-lib-extensions
git init && git add .
```

(`git add` matters: files a flake cannot see do not exist. A new
`home.nix` that was never `git add`ed is skipped silently.)

You now have:

```
flake.nix              two hosts, one registry
hosts/
  laptop.nix           host config, file form
  server/
    configuration.nix  host config, directory form
users/
  alice/               plain entry: on every host
    home.nix
  dave/                home AND system config
    home.nix
    configuration.nix
  eve/                 system-only user (no home)
    configuration.nix
  frank-base/          wildcard entry (frank@*)
  frank-laptop/        per-host extras (frank@laptop)
  ...
```

**Make it real before building:** the scaffolded host files are
placeholders (a fake root filesystem, no boot loader). Replace the
contents of `hosts/laptop.nix` with your machine's actual config --
typically an import of its `hardware-configuration.nix` plus a boot
loader:

```nix
{ ... }:
{
  imports = [ ./laptop-hardware.nix ];
  boot.loader.systemd-boot.enable = true;
  system.stateVersion = "25.05";
}
```

Then build and activate the host:

```
nixos-rebuild switch --flake .#laptop
```

This builds the SYSTEM only. The home configurations are exported per
user and host (e.g. `homeConfigurations."alice@laptop"`) and applied
later: on each user's first login, by the bootstrap service -- you
normally never run `home-manager` by hand.

## The registry

The heart of the setup -- one attrset shared by all hosts:

```nix
homeConfigurations = {
  "alice"        = ./users/alice;
  "bob@laptop"   = ./users/bob;
  "frank@*"      = ./users/frank-base;
  "frank@laptop" = ./users/frank-laptop;
};
```

Key forms:

| Key form        | Applies                                     |
|-----------------|---------------------------------------------|
| `"user@host"`   | on that host only                           |
| `"user@*"`      | on every host; MERGES with `"user@host"`    |
| `"user"`        | standalone default: only when NO @-entry    |
|                 | matched (never merged; a shadowed plain     |
|                 | entry prints a warning)                     |

Every value must be a **directory** containing one or both of:

- `home.nix` -- the user's home-manager configuration
- `configuration.nix` -- NixOS config for that user: extra groups,
  account tweaks, anything system-level

A directory with only `configuration.nix` is a **system-only user**:
account and groups, but no home configuration and no bootstrap.

The registry keys define the host's users -- there is no separate
`users` argument anywhere.

## Hosts

Each host is one entry in `buildNixosConfigurations`; the key is the
hostname. In your flake the full wiring looks like this (the scaffolded
`flake.nix` is exactly this shape):

```nix
{
  inputs = {
    nixpkgs.url =
      "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-lib-extensions = {
      url = "github:dvaerum/nixpkgs-lib-extensions";
      # avoid locking a second nixpkgs/home-manager
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    { nixpkgs-lib-extensions, ... }@inputs:
    let
      extLib = nixpkgs-lib-extensions.lib;
      system = "x86_64-linux";
      homeConfigurations = {
        # the registry from the previous section
        "alice" = ./users/alice;
      };
      # ONE host list for both outputs
      hosts = {
        # shared by every host; a host
        # entry overrides per argument
        _defaults = {
          inherit inputs system
            homeConfigurations;
        };
        laptop = { };
        server = {
          # override: no registry,
          # so no users on server
          homeConfigurations = { };
        };
      };
    in
    {
      nixosConfigurations =
        extLib.buildNixosConfigurations
          hosts;

      # "user@host" outputs for every
      # host: what the bootstrap runs
      homeConfigurations =
        extLib.buildHomeConfigurations
          hosts;
    };
}
```

Later snippets in this guide assume these bindings (`extLib`,
`inputs`, `system`, the registry) from this skeleton.

The reserved `_defaults` entry (never a valid hostname -- hostnames
cannot contain `_`) supplies arguments to every host. Merging is per
argument and the host entry wins entirely -- lists and attrsets are
NOT deep-merged. For "shared base plus per-host extras" use the
layered pairs instead: `modules` and `specialArgs` in `_defaults`,
`additionalModules` and `additionalSpecialArgs` on the host -- the
pairs combine by design. `_defaults` must not set `hostname` or the
`additional*` arguments (it throws).

The host's own configuration is imported by convention, relative to
your flake root:

- `hosts/<hostname>.nix`, or
- `hosts/<hostname>/configuration.nix`

Both existing at once is an error. Anything extra goes in `modules`.

With many machines, group them by kind: set `systemType = "vm";` on a
host and the lookup moves one folder deeper, to
`hosts/vm/<hostname>.nix` (or `hosts/vm/<hostname>/configuration.nix`).
The value also reaches your modules as the `systemType` specialArg,
so shared modules can branch on it. Without `systemType` nothing
changes -- no extra subfolder is consulted.

## Accounts

Every registry-derived user gets a login account automatically:
`userModuleFn` defaults to `normalUserModule`, which sets
`isNormalUser` and gives the user a **private primary group** named
after them (instead of the shared `users` group).

System accounts are recognized by uid and left untouched: when a
user's merged uid is below 1000 -- root, or a registry user whose
`configuration.nix` pins a reserved uid -- the module contributes
nothing (NixOS forbids `isNormalUser` on such accounts, and they
define their own group and shell). So `"root"` is a valid registry
entry: it gets its `home.nix`/`configuration.nix`, never account
changes.

Richer accounts -- build on the default:

```nix
userModuleFn = username: {
  imports = [ (extLib.normalUserModule username) ];
  users.users.${username} = {
    extraGroups = [ "networkmanager" ];
  };
};
```

Disable account creation entirely with `userModuleFn = null;`
(accounts must then come from your host config or the users'
`configuration.nix` files).

## The login bootstrap

When a host gets a non-empty registry, a systemd *user* service is
installed automatically. On a user's first login it runs

```
home-manager switch --flake <flakeRef>#<user>@<host>
```

in the background (login is never blocked). A stamp file in
`$XDG_STATE_HOME` (default `~/.local/state`) prevents re-runs; pass
`reactivateEveryLogin = true;` to re-apply on every new session
instead. `flakeRef` defaults to your flake (`inputs.self`) -- the
pinned copy from the last `nixos-rebuild`; point it at a mutable
checkout (e.g. `"/etc/nixos"`) if users should build from a live
tree.

For this to work your flake must export the home configurations for
EVERY host that has users -- the bootstrap on host X activates
`<flakeRef>#<user>@X`, which must exist. If that output is missing,
the service fails with "flake ... does not provide attribute
homeConfigurations..." on first login. The skeleton above covers it:
`buildHomeConfigurations hosts` produces the homes for every host in
the same list. (The underlying per-host function is
`homeConfigurationsBuilder`, if you need a single host's homes.)

### The bootstrap without the builders

`homeManagerBootstrapModule` is a plain NixOS module and can be used
on its own, for systems built without `nixosConfigurationsBuilder`.
A complete flake:

```nix
{
  inputs = {
    nixpkgs.url =
      "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-lib-extensions = {
      url =
        "github:dvaerum/nixpkgs-lib-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows =
        "home-manager";
    };
  };

  outputs =
    { nixpkgs, nixpkgs-lib-extensions, ... }@inputs:
    let
      extLib = nixpkgs-lib-extensions.lib;
      system = "x86_64-linux";
      homeConfigurations = {
        "alice" = ./users/alice;
      };
    in
    {
      # a system built WITHOUT the builders
      nixosConfigurations.laptop =
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./configuration.nix

            # accounts are YOUR job here; the
            # builders would have created them
            {
              users.users.alice = {
                isNormalUser = true;
              };
            }

            # installs the login service
            (extLib.homeManagerBootstrapModule {
              inherit inputs system
                homeConfigurations;
              hostname = "laptop";
              # reactivateEveryLogin = true;
              # flakeRef = "/etc/nixos";
            })
          ];
        };

      # the homes the bootstrap activates:
      # "alice@laptop" MUST exist here
      homeConfigurations =
        extLib.homeConfigurationsBuilder {
          inherit inputs system
            homeConfigurations;
          hostname = "laptop";
        };
    };
}
```

At login the service runs
`home-manager switch --flake <flakeRef>#alice@laptop` exactly as in
the builder setup. Two things the standalone module does NOT do
(they are `nixosConfigurationsBuilder` features): it never creates
user accounts, and it never imports the registry directories'
`configuration.nix` files -- only the registry KEYS are read, to
know which users to bootstrap.

The module is self-gating: with an empty registry, no home-manager
input, no flake reference, or no user matching the host, it
evaluates to an empty module -- safe to include unconditionally.

## What your inputs contribute automatically

For every flake input, by convention:

| Input exports                    | Effect                       |
|----------------------------------|------------------------------|
| `nixosModules.default`           | imported into every host     |
| `homeManagerModules.default` / `homeModules.default` | added to every home |
| `overlays.default`               | applied to `pkgs`            |
| `extendLib`                      | merged into the system `lib` |
| `lib`                            | namespaced: `lib.<name>.*`   |
| `nixpkgs-*` (package sets)       | `pkgs-*` specialArgs         |

The `default` export is auto-loaded. Without one, a set with exactly
ONE entry is unambiguous and that entry is used (sops-nix and
plasma-manager export their single module under a name, not
`default`). A set with SEVERAL entries and no `default` is treated
as a catalog of opt-in entries -- nixos-hardware, for example, ships
hundreds of mutually exclusive hardware profiles -- and contributes
nothing automatically; import the entries you want explicitly:

```nix
modules = [
  inputs.nixos-hardware
    .nixosModules.dell-xps-13-9310
];
```

An input's standalone `lib` export is added under its own name --
`lib.NixVirt.domain` in any module (and `pkgs.lib.NixVirt` too), no
wiring needed. It is namespaced, never merged flat: `extendLib` is
the convention for extending the flat lib. Collisions are handled by
who owns the name:

- a namespace this repo owns (`disko`, ...): the input's lib is
  MERGED into it, and the existing side wins every conflict -- an
  input can only add, never change. With the disko flake as input,
  `lib.disko` holds `declareZfsRootDisk` AND disko's own helpers.
- any other existing `lib` attribute (an input named `strings`
  would hit nixpkgs' own namespace): skipped with a warning --
  such an input name is almost always an accident; rename it.
- nixpkgs trees are not namespaced at all (their lib IS the base).

Your OWN flake's `lib` output is included too, renamed from `self`
to **`lib.flake`** (`lib.self` would read oddly). This is the
zero-wiring way to share helper functions with all your hosts:

```nix
# flake.nix outputs
lib = import ./common/helper-functions {
  inherit (nixpkgs) lib;
};
```

```nix
# any module, NixOS or home-manager
{ lib, ... }:
{
  imports = [
    (lib.flake.router-conf { ... })
  ];
}
```

(If you name an actual input `flake`, that input keeps the name and
your self lib is dropped with a warning.)

Opt an input out of the NixOS-module auto-import with
`excludeModuleInputs = [ "name" ];` (it does not affect home-manager
modules or overlays). Nixpkgs trees -- anything exposing both
`legacyPackages` and `lib.nixosSystem`, like the `nixpkgs-*` inputs
-- are never module-imported: they ship helper modules that would
break a system. Exporting `legacyPackages` alone (sops-nix does, for
its docs) does not exclude an input.

Inputs with nonstandard export names are normalized by a small table
keyed by input name -- currently `nur` (`modules.nixos` /
`modules.homeManager`). The home-manager input itself is detected by
capability, whatever you named it, and its NixOS module is never
auto-imported (it is used standalone).

## What your modules receive (specialArgs)

Both NixOS modules and home-manager modules get:

| Arg                   | Content                                  |
|-----------------------|------------------------------------------|
| `inputs`              | the whole flake inputs set               |
| `inputPkgs.<name>`    | every input's packages, pre-selected for |
|                       | the host's system                        |
| `pkgs-<variant>`      | package set per `nixpkgs-*` input        |
| `extLib`              | this repo's lib (also merged into `lib`) |
| `hostname`, `rootPath`, `tags`, `systemType` | call arguments |
| `listOfUsernames`     | the host's registry-derived users        |
| `username`            | home-manager configs only: whose home    |

Anything you pass as `specialArgs = { ... };` is merged LAST and can
override all of the above. `pkgs` is deliberately not a specialArg --
modules receive it from the module system.

Example -- use a package from an input without any wiring:

```nix
{ inputPkgs, ... }:
{
  environment.systemPackages = [
    inputPkgs.disko.disko-install
  ];
}
```

Input packages are deliberately NOT merged into `pkgs` (names would
shadow nixpkgs attributes); an input's own `overlays.default` is the
flake author's sanctioned way into `pkgs`.

## Common recipes

Add a user everywhere:

```
mkdir -p users/carol
git add users/carol
$EDITOR users/carol/home.nix
```

```nix
# flake.nix registry
"carol" = ./users/carol;
```

Give a user extra groups on one host only: create
`users/carol-work/configuration.nix` with the groups and register

```nix
"carol@*"    = ./users/carol;      # home everywhere
"carol@work" = ./users/carol-work; # extra config on work
```

Rename or add a host -- four places move together:

1. the attrset key in `buildNixosConfigurations` (also becomes
   `networking.hostName` by default)
2. the host file: `hosts/<name>.nix` or
   `hosts/<name>/configuration.nix`
3. a `homeConfigurationsBuilder` call with `hostname = "<name>";`
   (only if the host has users)
4. any `"user@<name>"` registry keys

Package-set knobs per host (full reference in [lib.md](lib.md)):

```nix
laptop = {
  inherit inputs system homeConfigurations;
  # reach modules as `tags` and label the
  # boot-menu entries (system.nixos.tags)
  tags = [ "gpu" ];
  # merged into nixpkgs.config
  nixpkgsConfig = { cudaSupport = true; };
  # unfree package names to allow
  allowedUnfreePackages = [ "steam" ];
  # applied to the nixpkgs SOURCE via applyPatches
  patches = [ ./patches/fix.patch ];
  # on top of the auto-collected input overlays
  extraOverlays = [ (final: prev: { ... }) ];
};
```

## Patching nixpkgs itself

For a nixpkgs fix that has not reached your channel yet (typically
an open pull request), a host can build from a patched COPY of the
nixpkgs source. Save the PR's diff into your repo:

```
curl -L -o patches/pr-12345.diff \
  https://github.com/NixOS/nixpkgs/pull/12345.diff
git add patches/
```

and point the host at it:

```nix
laptop = {
  patches = [ ./patches/pr-12345.diff ];
};
```

What it costs: the whole nixpkgs tree is copied into the store with
the patches applied, and that copy must be BUILT before evaluation
can continue (import-from-derivation) -- the first build pays a
one-time cost, and eval-only workflows such as
`nix flake check --no-build` stop working for that host.

When NOT to use it: to change or fix a single package, an overlay
(`extraOverlays`) is lighter and needs no source copy. Patches are
for what overlays cannot express: NixOS module fixes and other
eval-level changes.

## Gotchas

- **Untracked files are invisible to flakes.** `git add` new user
  directories and host files, or they are silently skipped.
- A plain `"user"` entry is IGNORED (with a warning) as soon as any
  `"user@..."` entry exists -- import its directory explicitly from
  an @-entry if you want to reuse it.
- "Every login" means every systemd user-manager instance: the
  bootstrap re-runs when the user's first session starts, not on
  each additional terminal login.
- If the bootstrap seems to do nothing: the registry must be
  non-empty, a home-manager input must exist, `inputs.self` (or
  `flakeRef`) must be set, and at least one matched user must ship a
  `home.nix` -- all four are required, and the service is simply
  absent otherwise.

## Verifying your setup

This repo's own test suite doubles as living documentation: the
example under [checks/example/](../checks/example/) is evaluated by
`nix flake check`, and two further VM tests boot a machine, log a
user in and run a real `home-manager switch`. Reading
[checks/builders/tests/](../checks/builders/tests/) shows the exact
guaranteed behavior of every feature described above.
