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
- Each user's home is activated by ONE of two mechanisms, chosen per
  user: **with the system** (default -- home-manager's NixOS module,
  applied by `nixos-rebuild switch`) or **on first login** (users
  listed in `loginHomes` -- a systemd user service runs
  `home-manager switch` in the background).
- NixOS modules, home-manager modules, overlays and lib extensions
  exported by your flake inputs are **wired in automatically**.

## Quick start

Everything here is flakes-based, so Nix must have the `nix-command`
and `flakes` experimental features enabled (e.g.
`experimental-features = nix-command flakes` in your `nix.conf`).

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
    home.nix
    configuration.nix
  frank-laptop/        per-host extras (frank@laptop)
    configuration.nix
  bob/ carol/ grace-base/     further key forms, see the registry
```

**Make it real before building**, in two places:

1. The scaffolded **host files** are placeholders (a fake root
   filesystem, no boot loader). Note that this still *activates* --
   it does not fail safe -- so replace the contents of
   `hosts/laptop.nix` with your machine's actual config first,
   typically an import of its `hardware-configuration.nix` plus a boot
   loader.
2. The scaffolded **registry** creates six real accounts (alice, bob,
   dave, eve, frank, grace) with their groups and, for the
   `loginHomes`, their bootstrap services. Replace those entries with
   your own users before the first switch.

A host file then looks like:

```nix
{ ... }:
{
  imports = [ ./laptop-hardware.nix ];
  boot.loader.systemd-boot.enable = true;
  system.stateVersion = "26.11";
}
```

Then build and activate the host:

```
nixos-rebuild switch --flake .#laptop
```

This builds the system INCLUDING the homes of every user not listed
in `loginHomes` -- those activate right there, with the switch. Homes
of `loginHomes` are exported per user and host instead
(e.g. `homeConfigurations."alice@laptop"`) and applied later: on each
user's first login, by the bootstrap service. Either way you normally
never run `home-manager` by hand.

## The registry

The heart of the setup -- one attrset shared by all hosts, passed to
the builders as `userRegistry` (NOT to be confused with the flake's
`homeConfigurations` OUTPUT, which the builders produce from it):

```nix
userRegistry = {
  "alice"        = ./users/alice;
  "bob@laptop"   = ./users/bob;
  "frank@*"      = ./users/frank-base;
  "frank@laptop" = ./users/frank-laptop;
};
```

Key forms:

| Key form      | Applies |
|---------------|---------|
| `"user@host"` | on that host only |
| `"user@*"`    | on every host; MERGES with a matching `"user@host"` |
| `"user"`      | standalone default, used only when NO @-entry matched -- never merged with @-entries, and a shadowed plain entry prints a warning |

Every value must be a **directory** containing one or both of:

- `home.nix` -- the user's home-manager configuration
- `configuration.nix` -- NixOS config for that user: extra groups,
  account tweaks, anything system-level

A directory with only `configuration.nix` is a **system-only user**:
account and groups, but no home configuration and no bootstrap.

The registry keys define the host's users -- there is no separate
`users` argument anywhere.

## Hosts

Each host is one entry in the hosts attrset you hand to
`buildConfigurations`; the key is the hostname. In your flake the full wiring looks like this (the scaffolded
`flake.nix` has this shape):

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
      userRegistry = {
        # the registry from the previous section
        "alice" = ./users/alice;
      };
      # ONE host list for both outputs
      hosts = {
        # shared by every host; a host
        # entry overrides per argument
        _defaults = {
          inherit inputs system
            userRegistry;
          # alice's home activates on
          # her first login; all other
          # homes ship with the system
          loginHomes = [ "alice" ];
        };
        laptop = { };
        server = {
          # override: no registry,
          # so no users on server
          userRegistry = { };
        };
      };
    in
    # ONE call, BOTH outputs:
    # nixosConfigurations for the hosts,
    # and the "user@host"
    # homeConfigurations the login
    # bootstrap activates
    extLib.buildConfigurations hosts;
}
```

`buildConfigurations` is the entry point to reach for. The two halves
are also available separately as `buildNixosConfigurations` and
`buildHomeConfigurations` (same hosts attrset), but exporting only the
first is a trap: a `loginHomes` user's home is resolved at their first
login, so a missing `homeConfigurations` output fails *then*, on a
booted machine, rather than at build time. One call cannot forget half.
It is also cheaper: each build function plans its hosts independently, so
calling both by hand evaluates the shared host-independent context twice
-- for a fleet, two full nixpkgs evaluations. `buildConfigurations` plans
once and takes both outputs from that one plan.

Later snippets in this guide assume these bindings (`extLib`,
`inputs`, `system`, the registry) from this skeleton.

The reserved `_defaults` entry (never a valid hostname -- a hostname
cannot START with `_`) supplies arguments to every host. Merging is per
argument and the host entry wins entirely -- lists and attrsets are
NOT deep-merged. For "shared base plus per-host extras" put the
addition in that host's `extra` slot -- ONE rule for every argument: a
bare key REPLACES the default, `extra.<key>` ADDS to it (lists
concatenate, attrsets merge with `extra` winning a conflict):

```nix
_defaults = { modules = [ ./base.nix ]; homeModules = [ ./direnv.nix ]; };
laptop = {
  extra.modules = [ ./desktop.nix ];   # base.nix AND desktop.nix
  extra.homeModules = [ ./extra.nix ]; # direnv.nix AND extra.nix
  nixpkgsConfig = { cudaSupport = true; };  # replaces outright
};
```

`_defaults` must not set `hostname` or `extra` (it throws).

The host's own configuration is imported by convention, relative to
your flake root:

- `hosts/<hostname>.nix`, or
- `hosts/<hostname>/configuration.nix`

Both existing at once is an error. Anything extra goes in `modules`.

With many machines, group them by kind: set `group = "vm";` on a
host and the lookup moves one folder deeper, to
`hosts/vm/<hostname>.nix` (or `hosts/vm/<hostname>/configuration.nix`).
The value also reaches your modules as
`config.nixpkgsLibExtensions.group`, so shared modules can branch
on it. Without `group` nothing changes -- no extra subfolder is
consulted. When the folder layout should NOT follow the
classification, `hostFolder = "vm";` selects the folder segment on its
own, whatever `group` says.

A group can also carry shared ARGUMENTS: a reserved `_groups.<name>`
entry in the hosts attrset is merged between `_defaults` and every
host declaring `group = "<name>";` -- later layers win per argument,
and a group entry's `extra` slot ADDS to the `_defaults` values just
like a host's does:

```nix
hosts = {
  _defaults = { inherit inputs system; };
  _groups.server = {
    tags = [ "headless" ];
    extra.modules = [ ./common/server.nix ];  # _defaults.modules PLUS this
  };
  web1 = { group = "server"; };
  web2 = { group = "server"; };
  laptop = { };                               # no group, no layer
};
```

When `_groups` is present, a host's `group` must name one of its
entries (a typo throws, listing the declared groups); without
`_groups`, `group` is just the free-form classification.

## Accounts

Every registry-derived user gets a login account automatically:
`userModule` defaults to `normalUserModule`, which sets
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
userModule = username: {
  imports = [ (extLib.normalUserModule username) ];
  users.users.${username} = {
    extraGroups = [ "networkmanager" ];
  };
};
```

Disable account creation entirely with `userModule = null;`
(accounts must then come from your host config or the users'
`configuration.nix` files).

## Two home mechanisms

Every registry user's `home.nix` is activated by exactly one of two
mechanisms; `loginHomes` selects which:

```
                     home.nix of a user
                             |
              in loginHomes? |
             no              |             yes
              v                             v
  built INTO the system         built as the flake output
  (home-manager NixOS           homeConfigurations
   module); activates on         ."user@host" (by
  nixos-rebuild switch          buildHomeConfigurations);
                                activated on FIRST LOGIN
                                by the bootstrap service
```

System-managed (the default) means the home is part of the system
closure: `useGlobalPkgs`/`useUserPackages` are enabled (both
`mkDefault`), a broken home config fails the system build, and no
flake outputs are involved. Each home receives `username` as a
module argument and gets `home.stateVersion` defaulted to the
CURRENT nixpkgs release -- but a home actually relying on that
moving default is warned (both mechanisms): pin it in the user's
`home.nix` (`home.stateVersion = "26.11";`) or fleet-wide via an
entry in the shared `homeModules` argument.

Login-managed exists for homes that should update independently of
system rebuilds. On the user's first login a systemd *user* service
runs

```
home-manager switch --flake <loginFlakeRef>#<user>@<host>
```

in the background (login is never blocked). A stamp file in
`$XDG_STATE_HOME` (default `~/.local/state`) prevents re-runs; pass
`loginReactivateEveryLogin = true;` to re-apply on every new session
instead. `loginFlakeRef` defaults to your flake (`inputs.self`) --
the pinned copy from the last `nixos-rebuild`; point it at a mutable
checkout (e.g. `"/etc/nixos"`) if users should build from a live
tree.

For login users your flake must export the home configurations for
EVERY host where they appear -- the bootstrap on host X activates
`<loginFlakeRef>#<user>@X`, which must exist. If that output is
missing, the service fails with "flake ... does not provide attribute
homeConfigurations..." on first login. The skeleton above covers it:
`buildConfigurations hosts` produces the homeConfigurations half from
that same host list. (The underlying single-user function is
`mkHomeConfiguration`, if you need one specific home.)

### The bootstrap without the builders

`homeManagerBootstrapModule` is a plain NixOS module and can be used
on its own, for systems built without `mkNixosSystem`.
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
      userRegistry = {
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
                userRegistry;
              hostname = "laptop";
              loginHomes = [ "alice" ];
              # loginReactivateEveryLogin =
              #   true;
              # loginFlakeRef = "/etc/nixos";
            })
          ];
        };

      # the homes the bootstrap activates:
      # "alice@laptop" MUST exist here
      homeConfigurations."alice@laptop" =
        extLib.mkHomeConfiguration {
          inherit inputs system
            userRegistry;
          hostname = "laptop";
          username = "alice";
        };
    };
}
```

At login the service runs
`home-manager switch --flake <loginFlakeRef>#alice@laptop` exactly as
in the builder setup. Two things the standalone module does NOT do
(they are `mkNixosSystem` features): it never creates
user accounts, and it never imports the registry directories'
`configuration.nix` files. It does read the matched registry
directories, but only to see which users ship a `home.nix` -- so an
entry that is not a directory, or has neither file, still throws.

The module is self-gating: with no matching login user, no
home-manager input, or no flake reference, it evaluates to an empty
module -- safe to include unconditionally.

## What your inputs contribute automatically

For every flake input, by convention:

| Input exports                    | Effect                       |
|----------------------------------|------------------------------|
| `nixosModules.default`           | imported into every host     |
| `homeModules.default`            | added to every home          |
| `overlays.default`               | applied to `pkgs`            |
| `libOverlays.default`            | merged into the system `lib` |
| `lib`                            | namespaced: `lib.<name>.*`   |
| `nixpkgs-*` (package sets)       | `nixpkgsLibExtensions.channels.<variant>` option |

The `default` export is auto-loaded. Without one, a set with exactly
ONE entry is unambiguous and that entry is used (sops-nix and
plasma-manager export their single module under a name, not
`default`). A set with SEVERAL entries and no `default` is ambiguous
-- nixos-hardware, for example, ships hundreds of mutually exclusive
hardware profiles -- and the builder refuses to guess: evaluation
throws and points at `inputContributions`, where you say which of them
you want. (It does not list the entries; a catalog has hundreds. Name
one that does not exist and *that* error lists them.)

### Selecting what an input contributes

`inputContributions` is keyed by input name, and each entry names the
entries to take per channel -- `nixosModules`, `homeModules` or
`overlays`. It is an ordinary builder argument, so it goes in
`_defaults` (applying to every host) or on a single host entry:

```nix
hosts = {
  _defaults = {
    inherit inputs system userRegistry;

    inputContributions = {
      # these entries, auto-imported in this order
      "nixos-raspberrypi".overlays =
        [ "bootloader" "vendor-kernel" ];
      # every entry (alphabetically)
      "some-input".homeModules = "*";
      # none: a catalog you import from by hand
      "nixos-hardware".nixosModules = null;
    };
  };

  laptop = {
    # the entries you opted out of above, imported explicitly
    extra.modules = [
      inputs.nixos-hardware
        .nixosModules.dell-xps-13-9310
    ];
  };
};
```

The four selection values are: a **list of names** (taken in the
order given), `"*"` (all of them), `null` or `[ ]` (none), and --
by leaving the channel out entirely -- the default `default`/single-entry
rule above. `libOverlays` and `lib` hold a single value rather than a
set, so for those only `null`/`[ ]` (off) and `"*"` (on) apply.

Two shorthands: `inputContributions."x" = null;` switches off *every*
channel of an input at once, and a function value is the escape hatch
for exports living under nonstandard paths --
`"x" = v: { nixosModules = v.modules.nixos; };`.

Selecting by name is checked, so a typo fails loudly instead of
quietly doing nothing: an unknown channel key, an entry the input does
not export, or a case keyed by an input that is not in `inputs` each
throw with the valid options listed. Opting a channel out affects
only the AUTOMATIC collection -- reaching an input by hand always
works:

```nix
"nixos-hardware".nixosModules = null;

modules = [
  inputs.nixos-hardware
    .nixosModules.dell-xps-13-9310
];
```

An input's standalone `lib` export is added under its own name --
`lib.NixVirt.domain` in any module (and `pkgs.lib.NixVirt` too), no
wiring needed. It is namespaced, never merged flat: a lib overlay
(`libOverlays.default = final: prev: { ... };`) is the convention for
extending the flat lib. Collisions are handled by who owns the name:

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
    (lib.flake.router-conf { /* your args */ })
  ];
}
```

(If you name an actual input `flake`, that input keeps the name and
your self lib is dropped with a warning.)

Two kinds of input are skipped by the NixOS-module auto-import on
their own: the home-manager input (the builder wires its module in
deliberately, where system-managed homes need it) and nixpkgs trees
-- anything exposing both `legacyPackages` and `lib.nixosSystem`,
like the `nixpkgs-*` inputs -- which ship helper modules that would
break a system. Exporting `legacyPackages` alone (sops-nix does, for
its docs) does not exclude an input. Both skips exist to stop the
builder from guessing, so an explicit selection overrides them:
`inputContributions."x".nixosModules = [ "the-one-i-mean" ];`.

Those skips are per channel, deliberately. A nixpkgs tree's `lib` is
also not namespaced (its lib IS the base lib), but its
`overlays.default` IS applied -- nixpkgs exports no overlays at all,
and a fork that exports one means it to be used. A tree shipping a
whole CATALOG of overlays is caught by the ambiguity throw like any
other catalog, and opted out per channel the same way.

The home-manager input itself is detected by capability, whatever
you named it, and its NixOS module is never auto-imported absent an
explicit selection (the builder wires it in deliberately where
system-managed homes need it).

## What your modules receive

Both NixOS modules and home-manager modules get a small set of
specialArgs -- the true import-time values, usable even in `imports`:

| Arg | Content |
|-----|---------|
| `inputs` | the whole flake inputs set |
| `extLib` | this repo's lib (also merged into `lib`) |
| `rootPath` | the root of the `hosts/<hostname>` convention |

Everything else the builder derives is declared as ordinary module
options under `nixpkgsLibExtensions.*`, in every NixOS module set and
in every home (both mechanisms). This table is the COMPLETE reference
of that namespace -- a check compares it against the declared options,
so it cannot silently miss one:

| Option | Content |
|--------|---------|
| `nixpkgsLibExtensions.tags` | host tags; modules can ADD tags (list definitions merge) |
| `nixpkgsLibExtensions.group` | the call argument of the same name (read-only) |
| `nixpkgsLibExtensions.users` | the host's registry-derived users (read-only) |
| `nixpkgsLibExtensions.inputPkgs.<name>` | every input's packages, pre-selected for the host's system (read-only) |
| `nixpkgsLibExtensions.channels.<variant>` | package set per `nixpkgs-*` input (read-only) |
| `nixpkgsLibExtensions.hostname` | homes only: the host the home is built for -- NixOS modules read `config.networking.hostName` |

Home-manager modules additionally receive `username` (whose home) as a
module argument.

Anything you pass as `specialArgs = { ... };` is merged alongside the
builder's own (a host adds to it with `extra.specialArgs`). The
builder-owned names and the option-backed ones (`hostname`, `tags`,
`group`, `users`, `inputPkgs`, `channels`, `username`) are reserved:
redefining one throws -- it would change only what modules see, not
what the builder did. Set the corresponding builder argument instead.
`pkgs` is deliberately not a specialArg -- modules receive it from the
module system.

Example -- use a package from an input without any wiring:

```nix
{ config, ... }:
{
  environment.systemPackages = [
    config.nixpkgsLibExtensions.inputPkgs.disko.disko-install
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
$EDITOR users/carol/home.nix
git add users/carol
```

(`git add` last, and only once the file exists: `git add` on an empty
directory stages nothing, which would leave the new `home.nix`
untracked and therefore invisible to the flake.)

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

Rename or add a host -- three places move together:

1. the attrset key in the hosts attrset (also becomes
   `networking.hostName` by default; since both outputs come from the
   one hosts attrset, the homeConfigurations follow automatically)
2. the host file: `hosts/<name>.nix` or
   `hosts/<name>/configuration.nix`
3. any `"user@<name>"` registry keys

Package-set knobs per host (full reference in [lib.md](lib.md)):

```nix
laptop = {
  # reach modules as config.nixpkgsLibExtensions.tags
  # and label the boot-menu entries (system.nixos.tags)
  tags = [ "gpu" ];
  # merged into nixpkgs.config
  nixpkgsConfig = { cudaSupport = true; };
  # unfree package names to allow -- shorthand for the nixpkgsConfig
  # recipe: nixpkgsConfig.allowUnfreePredicate =
  #   pkg: builtins.elem (lib.getName pkg) [ "steam" ];
  allowedUnfreePackages = [ "steam" ];
  # (permittedInsecurePackages is the same kind of shorthand, for
  #  nixpkgsConfig.permittedInsecurePackages = [ ... ];)
  # applied to the nixpkgs SOURCE via applyPatches
  patches = [ ./patches/fix.patch ];
  # on top of the auto-collected input overlays
  overlays = [ (final: prev: { myPkg = prev.hello; }) ];
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
`nix flake check --no-build` stop working for that host. For the
same reason a host with `patches` fails to evaluate at all under
`--no-allow-import-from-derivation` (as does this library's
`importIfNix`/`importIfNixOr`, whose parse probe is also a
during-evaluation build).

When NOT to use it: to change or fix a single package, an overlay
(`overlays`) is lighter and needs no source copy. Patches are
for what overlays cannot express: NixOS module fixes and other
eval-level changes.

## Deploying the fleet

The outputs are standard `nixosConfigurations` -- nothing about them is
specific to this library -- so anything that consumes a flake's
`nixosConfigurations` composes as-is:

```
# plain nixos-rebuild from an admin machine
nixos-rebuild switch --flake .#server --target-host root@server
```

deploy-rs and colmena work the same way: point their node definitions at
the same flake (deploy-rs activates a `nixosConfigurations` entry
directly; colmena's flake mode can wrap one via
`colmena.<name>.imports`), and derive the node list from the one hosts
attrset instead of maintaining a second copy of the fleet.

For selection conventions, each host's tags are readable from the
outside as
`nixosConfigurations.<host>.config.nixpkgsLibExtensions.tags` (the
merged option value, also labeling the boot menu via
`system.nixos.tags`) -- a deploy script can pick "every host tagged
`server`" by filtering the flake outputs over that list.

## Gotchas

- **Untracked files are invisible to flakes.** `git add` new user
  directories and host files, or they are silently skipped.
- Registry values should be **path values** (`./users/alice`), not
  absolute path strings (`"/home/me/users/alice"`): a string escapes
  the flake -- it is never copied to the store and fails under pure
  evaluation -- so it still works but warns.
- A plain `"user"` entry is IGNORED (with a warning) as soon as a
  `"user@*"` or `"user@<thishost>"` entry exists -- an @-entry naming
  some OTHER host does not shadow it -- import its directory explicitly from
  an @-entry if you want to reuse it.
- "Every login" means every systemd user-manager instance: the
  bootstrap re-runs when the user's first session starts, not on
  each additional terminal login.
- If the bootstrap seems to do nothing: at least one `loginHomes`
  name must match a registry user shipping a `home.nix` on this host,
  a home-manager input must exist, and `inputs.self` (or
  `loginFlakeRef`) must be set -- all are required, and the service
  is simply absent otherwise. Users NOT in `loginHomes` never touch
  the bootstrap: their homes activate with `nixos-rebuild switch`.
- A `loginHomes` name is only checked across the WHOLE hosts attrset:
  a name no host's registry mentions at all throws (typo), but a name
  that merely does not apply to some host is legal there -- one shared
  list in `_defaults` is the normal shape. In a DIRECT
  `mkNixosSystem`/`mkHomeConfiguration` call there
  is only one host in view, so unknown names are silently ignored.
- Switching mechanisms (moving a user out of `loginHomes` and back, or
  changing `loginFlakeRef`/the hostname) is safe on the bootstrap side:
  the stamp records the exact activation parameters, and a stamp whose
  content no longer matches counts as absent, so the next login
  re-runs. What nothing cleans up automatically: a user moved from
  `loginHomes` to system-managed keeps the OLD standalone home-manager
  profile generations -- run `home-manager expire-generations` (or
  remove the per-user home-manager profile) once the system-managed
  home is active, or the stale generations linger in the store.

## Verifying your setup

This repo's own test suite doubles as living documentation: the
example under [checks/example/](../checks/example/) is evaluated by
`nix flake check`, and three further VM tests boot a machine: one logs
a user in and runs a real `home-manager switch`, one verifies the
login-service wiring with a recording home-manager stub, and one
checks that a system-managed home activates with the system. Reading
[checks/builders/tests/](../checks/builders/tests/) shows the exact
guaranteed behavior of every feature described above.
