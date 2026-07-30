# Library reference

Generated from the doc comments in `lib/` -- do not edit by hand;
run `nix run .#gen-docs` after changing a doc comment. New to the
builders? Start with the
[getting-started guide](getting-started.md).

# attrsets


## `lib.attrsets.recursiveMerge`

Recursively merge a list of attribute sets.

Merge strategy:
- Single value: use as-is
- All lists: concatenate and deduplicate
- All attrsets: recursively merge
- Mixed types: last value wins (rightmost)

### Type
recursiveMerge :: [AttrSet] -> AttrSet

### Arguments
- **attrList**
  List of attribute sets to merge

### Example
```nix
recursiveMerge [
  { a = 1; b = { x = 1; }; c = [ 1 2 ]; }
  { a = 2; b = { y = 2; }; c = [ 2 3 ]; }
]
=> { a = 2; b = { x = 1; y = 2; }; c = [ 1 2 3 ]; }

recursiveMerge [
  { users = { alice = { shell = "bash"; }; }; }
  { users = { bob = { shell = "zsh"; }; }; }
]
=> { users = { alice = { shell = "bash"; }; bob = { shell = "zsh"; }; }; }

recursiveMerge [
  { tags = [ "web" "prod" ]; }
  { tags = [ "prod" "critical" ]; }
]
=> { tags = [ "web" "prod" "critical" ]; }
```


# disko


## `lib.disko.declareZfsRootDisk`

Declare a complete ZFS root disk as a NixOS module: GPT partitions
(boot/ESP, optional swap, zfs), the `zroot-<hostname>` pool, the
standard datasets (root, /var, /var/log, /nix/store, /home, optional
/tmp) plus one HOME dataset per user, with optional encryption keyed
to the motherboard's UUID.

Prerequisites: the disko NixOS module must be imported (it provides
the `disko.devices` options -- automatic when disko is a flake input
of a `nixosConfigurationsBuilder` setup), and ZFS requires
`networking.hostId` to be set.

### Example

```nix
# use in `imports`; the returned module receives config/pkgs/lib itself
# extLib = inputs.nixpkgs-lib-extensions.lib
imports = [
  (extLib.declareZfsRootDisk {
    devicePath = "/dev/disk/by-id/nvme-WDC_PC_SN479_WEFWOER-512G-1233_23425X589324";
    listOfUsernames = [
      "foo"
      { username = "bar"; mountpoint = "/home/bar2"; }
    ];
    hostname = "myhost";
    enableEncryption = false;
  })
];
```

### Type

```
declareZfsRootDisk :: Attribute -> Module
```

### Arguments

- **devicePath**
  The absolute path to the device

- **hostname**
  The host's name; the pool will be named: zroot-<HOSTNAME>

- **enableEncryption**
  Whether the pool should be encrypted. Default `true`.
  Currently the encryption is using the motherboards UUID as the key.
  You can find it with the command: `dmidecode --string system-uuid`

- **swapSize**
  Set the size (in GiB) of the SWAP partition. Default is `32`.
  Set it to `0` to disable having a SWAP partition.

- **useZfsForTmp**
  Select if `/tmp` should be a zfs dataset with
  `sync=disabled`, `setuid=off` and `devices=off` or
  if it should be `tmpfs`. Default `true` (zfs dataset).

- **listOfUsernames**
  A list of `string` or `attribute` element (may be mixed).
  The `string` element is: <USERNAME>.
  The `attribute` element is: { username = "<USERNAME>"; mountpoint = "<MOUNTPOINT>"; }

- **defineBootPartitions**
  Defines boot partitions for systems that are not `x86_64-linux` or `aarch64-linux`,
  or when boot partitions must be overwritten. Default `null` (use the
  predefined layout for the two supported platforms).

- **extraDatasets**
  An attribute set of additional zfs datasets, merged into the generated ones.
  Keys are dataset paths relative to the pool root (like the generated
  `ROOT/NixOS` or `HOME/<username>`), values are disko dataset definitions.
  Parent datasets are not created implicitly -- declare them too.
  Merged last, so it can also override a generated dataset.
  Example: { "DATA" = { type = "zfs_fs"; options.mountpoint = "none"; };
             "DATA/media" = { type = "zfs_fs"; mountpoint = "/srv/media"; options.mountpoint = "legacy"; }; }


# imports


## `lib.imports.importIfNix`

Import a path only when it contains valid, importable Nix; otherwise
return `{ }` (a harmless no-op module) with a warning naming the
reason. Exactly `importIfNixOr` with the default fixed to `{ }` -- see
that function for the full semantics; use it directly to provide your
own fallback value.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
# CI-safe secrets: locally imported, an
# encrypted blob on CI becomes { }
imports = [
  (extLib.importIfNix pkgs ./private.nix)
];

# warns: unsupported extension
extLib.importIfNix pkgs ./README.md
=> { }
# warns: does not exist
extLib.importIfNix pkgs ./missing.nix
=> { }
# some-dir has a default.nix
extLib.importIfNix pkgs ./some-dir
=> <the imported value>
```

### Type

```
importIfNix :: pkgs -> Path -> Any | { }
```

### Arguments

- **pkgs**
  A package set used to build the validity probe (IFD).

- **path**
  The path (or absolute path string) to inspect and maybe import.




## `lib.imports.importIfNixOr`

Import a path only when it contains valid, importable Nix; otherwise
return `default` instead of aborting evaluation. `importIfNix` is the
same function with the default fixed to `{ }`.

Made for setups where secret files are encrypted in the remote repo
(e.g. git-crypt): locally `private.nix` is plain Nix and gets imported;
on a CI checkout the same path is an encrypted blob, which fails the
validity probe and becomes the (non-secret) default -- so the same
configuration evaluates in both places.

Accepted: a regular file with the `.nix` suffix whose content parses as
Nix, or a directory whose `default.nix` does. Everything else yields
`default` WITH an evaluation warning naming the reason (missing path,
unsupported file extension, directory without default.nix, or content
that is not valid Nix) -- a skipped import is never a silent mystery.
When scanning directories, filter names by the `.nix` suffix first so
intentionally skipped files do not warn.

Content validity cannot be checked in pure evaluation (a parse error
from `import` is uncatchable, and `builtins.readFile` refuses binary
files), so the probe runs `nix-instantiate --parse` in a small
derivation -- import-from-derivation, built during evaluation on the
machine doing the evaluating, and cached per file content.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
# CI-safe secrets with non-secret placeholders:
extLib.importIfNixOr pkgs ./private.nix {
  tester = 1212;
}
# locally  => <the imported value>
# on CI    => { tester = 1212; } (warns)
```

### Type

```
importIfNixOr :: pkgs -> Path -> Any -> Any
```

### Arguments

- **pkgs**
  A package set used to build the validity probe (IFD).

- **path**
  The path (or absolute path string) to inspect and maybe import.

- **default**
  The value returned (with a warning) when `path` is not importable.


# nixos


## `lib.nixos.buildHomeConfigurations`

Build the standalone home-manager configurations of every host's
LOGIN-managed users in one call: takes the SAME hosts attrset as
`buildNixosConfigurations` (including `_defaults` and the allowlist
validation), applies `homeConfigurationsBuilder` per login user, and
merges everything into one `{ "<user>@<hostname>" = ...; }` set —
assignable to a flake's `homeConfigurations` output directly.

Only users listed in `loginUsers` (and shipping a `home.nix` for the
host) get an output: system-managed homes are part of the systems
built by `buildNixosConfigurations` and need no flake output. The
produced set is exactly what the login bootstrap activates
(`home-manager switch --flake <loginFlakeRef>#<user>@<host>`):

```nix
let
  hosts = {
    _defaults = {
      inherit inputs system userRegistry;
      loginUsers = [ "alice" ];
    };
    laptop = { };
    server = { userRegistry = { }; };
  };
in
{
  nixosConfigurations = extLib.buildNixosConfigurations hosts;
  homeConfigurations = extLib.buildHomeConfigurations hosts;
}
```

NixOS-only arguments in the attrset (`modules`, `userModuleFn`, ...)
are accepted and ignored here, so one hosts attrset can feed both
build functions (`homeSharedModules` applies on BOTH sides: to the
login homes built here and to the system-managed homes in
`buildNixosConfigurations`). Key collisions between hosts are
impossible: every produced key carries its own `@<hostname>` suffix.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
extLib.buildHomeConfigurations {
  _defaults = {
    inherit inputs system;
    userRegistry = {
      "alice" = ./users/alice;
      "bob"   = ./users/bob; # system-managed: no output
    };
    loginUsers = [ "alice" ];
  };
  laptop = { };
  desktop = { };
}
=>
{ "alice@laptop" = <homeManagerConfiguration>;
  "alice@desktop" = <homeManagerConfiguration>; }
```

### Type

```
buildHomeConfigurations ::
  { <hostname> = Attribute; } -> { "<user>@<hostname>" = HomeManagerConfiguration; }
```

### Arguments

- **hosts**
  The same attrset accepted by `buildNixosConfigurations` (same
  allowlists, same `_defaults` semantics); see there for the full
  key reference.




## `lib.nixos.buildNixosConfigurations`

Build several NixOS systems in one call: applies
`nixosConfigurationsBuilder` to every value of `hosts`, with the
attribute key as the hostname. The result has the same keys, so it can
be assigned to a flake's `nixosConfigurations` output directly.
Duplicate hostnames are impossible by construction (attrset keys are
unique); an entry that also sets a *conflicting* inner `hostname`
throws.

The reserved key `_defaults` (never a hostname -- hostnames cannot
contain `_`) provides arguments for every host. Merging is
per-argument and a host entry wins entirely: no deep-merging of lists
or attrsets. For "shared base plus per-host extras" use the layered
argument pairs instead -- `modules` (in `_defaults`) with
`additionalModules` (per host), and `specialArgs` with
`additionalSpecialArgs`; the pairs concatenate/merge by design.

The same hosts attrset is designed to also feed
`buildHomeConfigurations`, producing the matching `homeConfigurations`
outputs the login bootstrap needs -- define it once, pass it to both.

### Example

```nix
# in your flake:
# extLib = inputs.nixpkgs-lib-extensions.lib
nixosConfigurations = extLib.buildNixosConfigurations {
  _defaults = {
    inherit inputs system userRegistry;
    modules = [ ./common/base.nix ];
  };
  # each host's config is found by convention:
  # ./hosts/<hostname>.nix or
  # ./hosts/<hostname>/configuration.nix
  laptop = {
    # extends _defaults.modules
    additionalModules = [ ./common/laptop-extras.nix ];
  };
  server = {
    # per-argument override: replaces the registry entirely
    userRegistry = { };
  };
};
=>
{ laptop = <nixosSystem>; server = <nixosSystem>; }
```

### Type

```
buildNixosConfigurations ::
  { <hostname> = Attribute; } -> { <hostname> = NixosSystem; }
```

### Arguments

- **hosts**
  Attribute set mapping hostnames to `nixosConfigurationsBuilder`
  argument sets. The key provides `hostname`, so entries do not set
  it themselves. Host entry keys are checked against the same
  allowlist as `_defaults` plus the per-host-only keys
  (`additionalModules`, `additionalSpecialArgs`, and a redundant
  `hostname` equal to the attribute key); anything else throws, so
  typos and leftover arguments fail loudly.

- **_defaults**
  Optional reserved entry of `hosts` (never a hostname): arguments
  merged under every host entry, the host winning per argument. Can
  provide a default for every `nixosConfigurationsBuilder` argument
  except the per-host ones:
  
  - `inputs`
  - `system`
  - `nixpkgs`
  - `rootPath`
  - `modules`
  - `userModuleFn`
  - `userRegistry`
  - `loginUsers`
  - `homeSharedModules` (applies to BOTH mechanisms: system-managed
    homes here, login-managed homes in `buildHomeConfigurations`)
  - `loginFlakeRef`
  - `loginReactivateEveryLogin`
  - `tags`
  - `systemType`
  - `patches`
  - `extraOverlays`
  - `allowedUnfreePackages`
  - `permittedInsecurePackages`
  - `nixpkgsConfig`
  - `specialArgs`
  - `homeManager`
  - `inputSpecialCases`
  
  This list is an enforced ALLOWLIST: any other key throws, so typos
  (`homeConfiguration`, ...) fail loudly instead of being dropped
  silently. `hostname` (it comes from each attribute key) and the
  `additional*` arguments (the per-host halves of the layered pairs)
  get their own explanatory errors.




## `lib.nixos.homeConfigurationsBuilder`

Build ONE user's standalone home-manager configuration for one host —
the single-user primitive underneath `buildHomeConfigurations`, which
calls it for every login-managed user of every host. Use it directly
to export an individual home:

```nix
homeConfigurations."alice@laptop" =
  extLib.homeConfigurationsBuilder {
    inherit inputs system;
    hostname = "laptop";
    username = "alice";
    userRegistry."alice" = ./users/alice;
  };
```

The user's `home.nix` files come from the `userRegistry` entries
matching the host (`"<user>@<host>"` and `"<user>@*"` merge; plain
`"<user>"` is the standalone fallback). Companion `configuration.nix`
files are ignored here — they are system configuration, imported by
`nixosConfigurationsBuilder`. Shares the package set, `specialArgs`
and auto-collected home-manager modules with the other builders (it
accepts the same shared options). The home-manager input is detected
by capability (its `lib` exposes `homeManagerConfiguration`),
regardless of the input's name.

Throws when no home-manager input exists or the user has no matching
`home.nix` on this host — a single requested home that cannot be
built is an error, not an empty result.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
extLib.homeConfigurationsBuilder {
  inherit inputs;
  hostname = "laptop";
  system   = "x86_64-linux";
  username = "alice";
  userRegistry = {
    "alice@*"      = ./users/alice;
    "alice@laptop" = ./users/alice-laptop; # merged in on laptop
  };
}
=>
<homeManagerConfiguration for alice@laptop>
```

### Type

```
homeConfigurationsBuilder :: Attribute -> HomeManagerConfiguration
```

### Arguments

- **inputs**
  The flake's `inputs` set. The home-manager input is detected by capability.

- **hostname**
  The host name the home is built for (selects the matching registry
  entries).

- **username**
  The user whose home to build.

- **system**
  The system double, e.g. `"x86_64-linux"`.

- **userRegistry**
  The user registry (same shape as in `nixosConfigurationsBuilder`);
  only the entries matching `username` on `hostname` are used here.
  Default `{ }`.
  NOTE: in a git-backed flake, `git add` new files or they are
  invisible to the flake and skipped silently.

- **homeSharedModules**
  home-manager modules added to the home configuration, on top of those
  auto-collected from `inputs`. Default `[ ]`.

The home configuration gets overridable (`mkDefault`) values for
`home.username` (the user), `home.homeDirectory` (`/home/<user>`) and
`home.stateVersion` -- the latter tracks the CURRENT nixpkgs release,
so pin it in the user's `home.nix` if you rely on stateVersion
semantics.

nixpkgs, systemType, specialArgs, additionalSpecialArgs, tags, patches,
nixpkgsConfig, extraOverlays, allowedUnfreePackages,
- **permittedInsecurePackages, rootPath**
  Shared options (see `nixosConfigurationsBuilder`).




## `lib.nixos.homeManagerBootstrapModule`

A NixOS module that provisions each user's standalone home-manager profile on
login, via a systemd *user* service that runs `home-manager switch` in the
background (so login is never hard-blocked). First-login-only by default.

`nixosConfigurationsBuilder` includes this module automatically when it
has `loginUsers`, so it normally does not need to be wired up by hand —
direct use is for custom setups that build their NixOS systems some
other way. It is driven by the `userRegistry` filtered by `loginUsers`
(the same arguments the builders take) but is otherwise independent of
the builders. Self-gating: when no login user matches, the home-manager
input is missing or the flake reference is unset, the module is empty.

### Example

```nix
# Only needed when NOT using nixosConfigurationsBuilder:
# extLib = inputs.nixpkgs-lib-extensions.lib
{
  imports = [
    (extLib.homeManagerBootstrapModule {
      inherit inputs;
      hostname = "laptop";
      system   = "x86_64-linux";
      userRegistry = { "alice" = ./users/alice; };
      loginUsers = [ "alice" ];
    })
  ];
}
```

See
[The bootstrap without the builders](getting-started.md#the-bootstrap-without-the-builders)
for a complete standalone flake, including what this module does
NOT do compared to the builder setup.

### Type

```
homeManagerBootstrapModule :: Attribute -> Module
```

### Arguments

- **inputs**
  The flake's `inputs` set (home-manager detected by capability; `self` used
  as the default flake reference).

- **hostname**
  The host name; the `@<host>` suffix of the flake attribute to activate.

- **system**
  The system double, e.g. `"x86_64-linux"`.

- **userRegistry**
  The user registry (as in `nixosConfigurationsBuilder`). Default `{ }`.

- **loginUsers**
  The usernames whose homes are login-managed; only these are
  bootstrapped (and only when the registry gives them a `home.nix`
  on this host). Default `[ ]` (module is empty).

- **loginFlakeRef**
  Flake reference for `home-manager switch --flake <ref>#<user>@<host>`;
  the flake at this reference must export those
  `homeConfigurations."<user>@<host>"` outputs. The default
  `inputs.self` is the immutable store copy of your flake the system
  was built from (homes match the last `nixos-rebuild`); use a mutable
  reference like `"/etc/nixos"` to build homes from a live checkout.
  Default `inputs.self`.

- **loginReactivateEveryLogin**
  Re-activate on every login instead of only the first. Default `false`.

- **homeManager**
  Explicit home-manager input, bypassing capability detection.
  Default `null` (detect).




## `lib.nixos.nixosConfigurationsBuilder`

Build a NixOS system for a host.

The flake `inputs` are passed as a field, and a number of things are wired in
automatically when the matching input exists:

- NixOS modules from any input exposing `nixosModules.default` (excluded:
  the home-manager input, since it is used standalone, and nixpkgs trees
  -- anything with `legacyPackages` AND `lib.nixosSystem` -- whose helper
  modules would break the system). The `default` export is auto-loaded;
  without one, a set with exactly one entry is used as-is (sops-nix
  style), while a multi-entry set with no `default` is ambiguous
  (nixos-hardware style catalogs) and the builder THROWS rather than
  guess, listing the exported entries and the selections that resolve
  it -- see `inputSpecialCases`, which also narrows a channel to named
  entries or switches it off.
- overlays from any input exposing `overlays.default` (same rule).
- lib extensions from any input exposing an `extendLib` function; this repo's
  own extensions are always applied to the system `lib` and also passed as the
  `extLib` specialArg.
- each input's standalone `lib` export, namespaced by input name:
  `lib.<inputName>` in modules and `pkgs.lib.<inputName>` (e.g.
  `lib.NixVirt.domain`). Never merged flat -- `extendLib` is the
  composable way into the flat lib -- and never overwriting: if the
  name is a namespace this repo owns (`disko`, ...) the input's lib is
  MERGED into it with the existing side winning every conflict (so a
  `disko` input's helpers join `declareZfsRootDisk` under `lib.disko`);
  any other existing name is skipped with a warning, and nixpkgs trees
  are not namespaced at all (their lib is the base). The consuming
  flake's own `lib` output (`inputs.self`) is renamed to `lib.flake`
  -- export your helper functions there and every module gets them as
  `lib.flake.<helper>` with zero wiring.
- every `nixpkgs-*` input as a `pkgs-*` specialArg (e.g. `inputs.nixpkgs-unstable`
  becomes the `pkgs-unstable` specialArg).

The whole `inputs` set is also passed through as the `inputs` specialArg
(and home-manager extraSpecialArg), so modules can reach anything not
covered by those conventions (e.g. `inputs.fenix`) themselves — the
builders carry no policy for specific inputs. The only per-input hook
is a normalization table for flakes with nonstandard export names,
applied strictly by input name -- currently empty (NUR, its one
former entry, contributes via `overlays.default` like any other
input).
As a convenience, `inputPkgs` holds every input's packages pre-selected
for the host's system (`inputPkgs.disko.disko-install`); they are
deliberately not merged into `pkgs`, where input names would shadow
nixpkgs attributes.

The host's own configuration is included by convention: relative to
`rootPath` (default: the consuming flake, `inputs.self`), either
`hosts/<hostname>.nix` or `hosts/<hostname>/configuration.nix` is
imported automatically when it exists (both existing is an error).
Setting `systemType` groups hosts one folder deeper: the lookup then
happens under `hosts/<systemType>/` instead of `hosts/`.

The host's users come from ONE `userRegistry` — every user gets an
account and their `configuration.nix` imported into the system. How
each user's `home.nix` is activated is selected by `loginUsers`:

- not listed (the default) — SYSTEM-managed home: wired into the
  system via home-manager's NixOS module
  (`home-manager.users.<user>`), activated by `nixos-rebuild
  switch`. No flake outputs, no bootstrap.
- listed in `loginUsers` — LOGIN-managed home: activated on first
  login by the bootstrap (`homeManagerBootstrapModule`) running
  `home-manager switch --flake <loginFlakeRef>#<user>@<host>`; the
  flake must export those `homeConfigurations` outputs (built by
  `buildHomeConfigurations` from the same hosts attrset).

A home is managed by exactly one mechanism, by construction.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
extLib.nixosConfigurationsBuilder {
  inherit inputs;
  hostname = "laptop";
  system   = "x86_64-linux";
  nixpkgs  = inputs.nixpkgs;
  # ./hosts/laptop.nix (or ./hosts/laptop/configuration.nix) is
  # imported automatically; `modules` is only for anything extra.

  # ALL users: accounts + configuration.nix, and home.nix activated
  # with the system (home-manager NixOS module) unless listed in
  # loginUsers. Every value is a DIRECTORY with home.nix and/or
  # configuration.nix.
  userRegistry = {
    "alice@*"      = ./users/alice;        # on every host
    "alice@laptop" = ./users/alice-laptop; # merged in on laptop
    "bob"          = ./users/bob;          # only when no bob@... matches
  };
  # bob's home.nix activates on his first login instead (needs the
  # homeConfigurations outputs from buildHomeConfigurations)
  loginUsers = [ "bob" ];
}
=>
<nixosSystem>
```

The system is returned BARE (like `homeConfigurationsBuilder`), so
assign it to your flake's `nixosConfigurations` output under an
explicit key, e.g.
`nixosConfigurations.laptop = extLib.nixosConfigurationsBuilder { ... }`
— or use `buildNixosConfigurations` to build a whole keyed set of
hosts in one call.

### Type

```
nixosConfigurationsBuilder :: Attribute -> NixosSystem
```

### Arguments

- **inputs**
  The flake's `inputs` set. Used to auto-discover modules, overlays, lib
  extensions and `nixpkgs-*` variants.

- **hostname**
  The host name.

- **system**
  The system double, e.g. `"x86_64-linux"`.

- **nixpkgs**
  The single preferred nixpkgs flake used to build the system. Default `inputs.nixpkgs`.

- **modules**
  Extra NixOS modules, on top of those auto-collected from `inputs` and
  the host's own `hosts/<hostname>(.nix|/configuration.nix)`. Default `[ ]`.

- **additionalModules**
  Further NixOS modules, appended after `modules`. Default `[ ]`.
  With `buildNixosConfigurations` this is the per-host half of the
  layered pair: shared modules go in `_defaults.modules`, a host's
  extras go here.

- **userModuleFn**
  A function `username -> NixOS module`, applied for each user derived
  from the `userRegistry`. Defaults to `normalUserModule`, which creates
  a normal login account per user; pass your own function for richer
  accounts, or `null` to disable account creation entirely.

- **userRegistry**
  THE user registry: every host user, whatever their home mechanism.
  Every value must be a DIRECTORY containing `home.nix` (the user's
  home-manager config) and/or `configuration.nix` (NixOS config for
  that user: the account, its groups, ...). `configuration.nix` files
  are imported into the system automatically. `home.nix` files are
  wired into `home-manager.users.<user>` via home-manager's NixOS
  module -- built and activated WITH the system on `nixos-rebuild
  switch` (`useGlobalPkgs`/`useUserPackages` default to true,
  overridable; each home gets `home.stateVersion` defaulted to the
  CURRENT nixpkgs release, so pin it in the user's `home.nix` if you
  rely on stateVersion semantics, and receives `username` as a module
  argument) -- unless the user is listed in `loginUsers`. A
  directory with only a `configuration.nix` is a system-only user
  (account, no home). Keys select where an entry applies:
    `"<user>@<host>"`  this host only
    `"<user>@*"`       every host; MERGES with a matching `"<user>@<host>"`
    `"<user>"`         standalone default, used only when NO @-entry
                       matched -- never merged with @-entries (a shadowed
                       plain entry triggers an eval warning; import its
                       directory explicitly from an @-entry to reuse it)
  Example: with `"alice@*"` and `"alice@laptop"` both defined, both
  apply on laptop; a plain `"alice"` would then never be used anywhere.
  The keys define the host's users (exposed as `listOfUsernames`).
  `null` or `{ }` disables it. Default `{ }`.
  WARNING: in a git-backed flake only TRACKED files exist -- `git add` a
  new home.nix/configuration.nix or it is skipped silently.

- **loginUsers**
  List of usernames (from `userRegistry`) whose `home.nix` is
  LOGIN-managed instead of system-managed: not part of the system,
  activated on the user's first login by the bootstrap via
  `home-manager switch --flake <loginFlakeRef>#<user>@<host>` -- the
  flake must export those `homeConfigurations` outputs (built by
  `buildHomeConfigurations` from the same hosts attrset). Accounts
  and `configuration.nix` handling are unaffected. Names not
  matching any of this host's users are ignored (the list is
  usually shared through `_defaults` across hosts). Default `[ ]`
  (every home is system-managed).

- **loginFlakeRef**
  Where the login bootstrap finds the home configurations of
  `loginUsers` users: on first login it runs
  `home-manager switch --flake <loginFlakeRef>#<user>@<hostname>`, so the
  flake at this reference must export
  `homeConfigurations."<user>@<hostname>"`.
  The default `inputs.self` is the IMMUTABLE store copy of your flake
  that the running system was built from -- homes then always match
  the last `nixos-rebuild`, but local edits are invisible until the
  next rebuild. Point it at a mutable checkout (e.g. `"/etc/nixos"`
  or `"git+https://..."`) to make the bootstrap build from the live
  tree instead. Irrelevant without `loginUsers` users.
  Default `inputs.self`.

- **loginReactivateEveryLogin**
  Bootstrap re-activates on every login instead of only the first.
  Irrelevant without `loginUsers` users. Default `false`.

- **homeSharedModules**
  home-manager modules added to every SYSTEM-managed home (on top of
  those auto-collected from `inputs`). The same argument is read by
  `homeConfigurationsBuilder`/`buildHomeConfigurations` for the
  login-managed homes, so in a shared hosts attrset it applies to
  both kinds. Default `[ ]`.

- **tags**
  List of string tags, passed to modules as the `tags` specialArg and
  set as `system.nixos.tags` (mkDefault) so they label the host's
  boot-menu entries; a host defining that option itself overrides
  this. Tags carry no other behavior. Default `[ ]`.

- **nixpkgsConfig**
  Attribute set merged into `nixpkgs.config` for the host's package
  set -- e.g. `{ cudaSupport = true; }`. Merged last, so it can also
  override what `allowedUnfreePackages`/`permittedInsecurePackages`
  produced. Default `{ }`.

- **patches**
  Patch files applied to the nixpkgs SOURCE tree (via `applyPatches`)
  before the system is evaluated from it. Default `[ ]` (no patching,
  no source copy). See
  [Patching nixpkgs itself](getting-started.md#patching-nixpkgs-itself)
  for an example and the costs involved.

- **extraOverlays**
  Overlays applied on top of the ones auto-collected from `inputs`.
  Default `[ ]`.

- **allowedUnfreePackages**
  Unfree package names to allow (matched by `lib.getName` via
  `allowUnfreePredicate`). Default `[ ]`.

- **permittedInsecurePackages**
  Passed through to `nixpkgs.config.permittedInsecurePackages`.
  Default `[ ]`.

- **specialArgs**
  Extra specialArgs merged after everything the builder assembled
  (including `inputs`, `rootPath`, ...), overriding it. Default `{ }`.

- **additionalSpecialArgs**
  Further specialArgs merged after `specialArgs`, overriding it on
  conflicts. Default `{ }`. With `buildNixosConfigurations` this is
  the per-host half of the layered pair: shared specialArgs go in
  `_defaults.specialArgs`, a host's extras go here.

- **systemType**
  Free-form host classification, e.g. `"vm"` or `"server"`. Passed to
  modules as the `systemType` specialArg, and when non-null the host
  config convention looks under `hosts/<systemType>/` instead of
  `hosts/`. Default `null` (no grouping folder).

- **rootPath**
  The root for the `hosts/<hostname>` convention and the `rootPath`
  specialArg. Default `inputs.self` (the consuming flake); throws
  when neither is available.

- **homeManager**
  Explicit home-manager input, bypassing the capability detection --
  use it when several inputs look like home-manager (the detection
  warns and picks the alphabetically first otherwise). Default `null`
  (detect).

- **inputSpecialCases**
  Per-input control of the auto-collection, keyed by input NAME and
  merged over the built-in table. Each entry takes one of three forms:
    `null`                 the input contributes NOTHING, to any channel
    `{ <channel> = ...; }` a per-channel SELECTION (below)
    a function             escape hatch for exports living under
                           nonstandard paths: maps the input onto the
                           convention attributes, e.g.
                           `v: { nixosModules = v.modules.nixos; }`
  A selection value is a list of entry names (auto-imported in the order
  given), `"*"` (every entry, alphabetically), or `null`/`[ ]` (none).
  The selectable channels are `nixosModules`, `homeModules` and
  `overlays`; `extendLib` and `lib` hold a single value, so for them only
  `null`/`[ ]` (off) and `"*"` (on) apply. Naming entries is how you take
  SEVERAL of a catalog's exports -- and it is validated: an unknown
  channel key, an unknown entry name, or a case keyed by an input that is
  not in `inputs` all throw, listing the valid options. An explicit
  selection also overrides the built-in skips (the home-manager input,
  nixpkgs trees), which only exist to prevent guessing. Only the
  AUTOMATIC contributions are affected: an input reached by hand via the
  `inputs`/`inputPkgs` specialArgs always works.
  Example: `inputSpecialCases."nixos-raspberrypi".overlays =
  [ "bootloader" "vendor-kernel" ];`
  Default `{ }`.

`homeConfigurationsBuilder` accepts this same shared set, so both
builders can be called with one common argument attrset.




## `lib.nixos.normalUserModule`

A function from a username to a NixOS module declaring that user as a
normal account whose primary group is a private group named after the
user (the Debian/Fedora "user private group" scheme, instead of NixOS's
shared `users` group) -- so by default a user is only a member of their
own group.

This is the default `userModuleFn` of `nixosConfigurationsBuilder`, so
every user derived from the `userRegistry` gets a login
account automatically. Pass your own function when accounts need more,
or `userModuleFn = null` to disable account creation.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
extLib.normalUserModule "alice"
=>
# a module equivalent to:
{
  users.users.alice = {
    isNormalUser = true;
    group = "alice"; # overridable with a plain assignment
  };
  users.groups.alice = { };
}
# System accounts are left untouched: when the user's merged uid is
# below 1000 (root, or a configuration.nix pinning a reserved uid)
# the module contributes nothing -- NixOS forbids isNormalUser on
# such accounts, and they define their own group and shell. So
# "root" is a valid registry entry: it only gets its home.nix /
# configuration.nix, never account changes.

# a custom userModuleFn can build on it:
userModuleFn = username: {
  imports = [ (extLib.normalUserModule username) ];
  users.users.${username}.extraGroups = [ "networkmanager" ];
};
```

### Type

```
normalUserModule :: String -> Module
```

### Arguments

- **username**
  The name of the user account (and its private group) to create.


# strings


## `lib.strings.stringToTitle`

Capitalize the first character of a string.

### Type
stringToTitle :: String -> String

### Arguments
- **text**
  The input string to capitalize

### Example
```nix
stringToTitle "hello world"
=> "Hello world"

stringToTitle "foobar"
=> "Foobar"

stringToTitle ""
=> ""
```


