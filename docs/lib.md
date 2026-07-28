# attrsets {#sec-functions-library-attrsets}


## `lib.attrsets.recursiveMerge` {#lib.attrsets.recursiveMerge}

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


# disko {#sec-functions-library-disko}


## `lib.disko.declareZfsRootDisk` {#lib.disko.declareZfsRootDisk}

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


# imports {#sec-functions-library-imports}


## `lib.imports.importIfNix` {#lib.imports.importIfNix}

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




## `lib.imports.importIfNixOr` {#lib.imports.importIfNixOr}

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


# nixos {#sec-functions-library-nixos}


## `lib.nixos.buildNixosConfigurations` {#lib.nixos.buildNixosConfigurations}

Build several NixOS systems in one call: applies
`nixosConfigurationsBuilder` to every value of `hosts`, with the
attribute key as the hostname. The result has the same keys, so it can
be assigned to a flake's `nixosConfigurations` output directly.
Duplicate hostnames are impossible by construction (attrset keys are
unique); an entry that also sets a *conflicting* inner `hostname`
throws.

### Example

```nix
# in your flake:
# extLib = inputs.nixpkgs-lib-extensions.lib
nixosConfigurations = extLib.buildNixosConfigurations {
  # each host's config is found by convention:
  # ./hosts/<hostname>.nix or
  # ./hosts/<hostname>/configuration.nix
  laptop = {
    inherit inputs system homeConfigurations;
  };
  server = {
    inherit inputs system;
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
  it themselves.




## `lib.nixos.homeConfigurationsBuilder` {#lib.nixos.homeConfigurationsBuilder}

Build the standalone home-manager configurations for a host's users, from an
explicit registry, keyed `"<user>@<hostname>"`.

Shares the package set, `specialArgs` and auto-collected home-manager modules
with `nixosConfigurationsBuilder` (it accepts the same shared options). The
home-manager input is detected by capability (its `lib` exposes
`homeManagerConfiguration`), regardless of the input's name; when no such
input exists the result is an empty set.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
extLib.homeConfigurationsBuilder {
  inherit inputs;
  hostname = "laptop";
  system   = "x86_64-linux";
  # Every value is a DIRECTORY with home.nix and/or configuration.nix.
  # "alice@*" applies everywhere and MERGES with "alice@laptop" here;
  # "bob" is a standalone default (used since no bob@... matches).
  homeConfigurations = {
    "alice@*"      = ./users/alice;
    "alice@laptop" = ./users/alice-laptop;
    "bob"          = ./users/bob;
  };
}
=>
{
  "alice@laptop" = { ... };
  "bob@laptop" = { ... };
}
```

Assign the result to your flake's `homeConfigurations` output.

### Type

```
homeConfigurationsBuilder :: Attribute -> Attribute
```

### Arguments

- **inputs**
  The flake's `inputs` set. The home-manager input is detected by capability.

- **hostname**
  The host name; the `@<host>` suffix of each generated home configuration.

- **system**
  The system double, e.g. `"x86_64-linux"`.

- **homeConfigurations**
  Registry of user configuration DIRECTORIES, each containing `home.nix`
  and/or `configuration.nix`. Key forms: `"<user>@<host>"` (this host),
  `"<user>@*"` (every host; merges with a matching host entry), and
  `"<user>"` (standalone default, only used when no @-entry matched).
  This builder imports the matched `home.nix` files; companion
  `configuration.nix` files are ignored here but imported into the system
  by `nixosConfigurationsBuilder` (account/groups). Directories with only
  a `configuration.nix` are system-only users: no home output here.
  Default `{ }`. NOTE: in a git-backed flake, `git add` new files or they
  are invisible to the flake and skipped silently.

- **homeSharedModules**
  home-manager modules added to every home configuration, on top of those
  auto-collected from `inputs`. Default `[ ]`.

Each home configuration gets overridable (`mkDefault`) values for
`home.username` (the user), `home.homeDirectory` (`/home/<user>`) and
`home.stateVersion` -- the latter tracks the CURRENT nixpkgs release,
so pin it in the user's `home.nix` if you rely on stateVersion
semantics.

nixpkgs, systemType, specialArgs, desktopEnvironment, tags, patches,
- **extraOverlays, allowedUnfreePackages, permittedInsecurePackages, rootPath**
  Shared options (see `nixosConfigurationsBuilder`).




## `lib.nixos.homeManagerBootstrapModule` {#lib.nixos.homeManagerBootstrapModule}

A NixOS module that provisions each user's standalone home-manager profile on
login, via a systemd *user* service that runs `home-manager switch` in the
background (so login is never hard-blocked). First-login-only by default.

`nixosConfigurationsBuilder` includes this module automatically when it is
given a non-empty `homeConfigurations` registry, so it normally does not need
to be wired up by hand — direct use is for custom setups that build their
NixOS systems some other way. It is driven by the home-configuration
*registry* (the same one passed to `homeConfigurationsBuilder`) but is
otherwise independent of the builders. Self-gating: when the registry is
empty, the home-manager input is missing, the flake reference is unset or no
user matches, the module is empty.

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
      homeConfigurations = { "alice" = ./users/alice; };
    })
  ];
}
```

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

- **homeConfigurations**
  The same registry passed to `homeConfigurationsBuilder`; its keys define
  which users are bootstrapped on this host. Default `{ }`.

- **flakeRef**
  Flake reference for `home-manager switch --flake <ref>#<user>@<host>`.
  Default `inputs.self`.

- **reactivateEveryLogin**
  Re-activate on every login instead of only the first. Default `false`.




## `lib.nixos.nixosConfigurationsBuilder` {#lib.nixos.nixosConfigurationsBuilder}

Build a NixOS system for a host.

The flake `inputs` are passed as a field, and a number of things are wired in
automatically when the matching input exists:

- NixOS modules from any input exposing `nixosModules` (excluded: the
  home-manager input, since it is used standalone, and package-set flakes
  like `nixpkgs-*` -- anything with `legacyPackages` -- whose helper
  modules would break the system; opt out more via `excludeModuleInputs`).
- overlays from any input exposing `overlays`.
- lib extensions from any input exposing an `extendLib` function; this repo's
  own extensions are always applied to the system `lib` and also passed as the
  `extLib` specialArg.
- every `nixpkgs-*` input as a `pkgs-*` specialArg (e.g. `inputs.nixpkgs-unstable`
  becomes the `pkgs-unstable` specialArg).

The whole `inputs` set is also passed through as the `inputs` specialArg
(and home-manager extraSpecialArg), so modules can reach anything not
covered by those conventions (e.g. `inputs.fenix`) themselves — the
builders carry no policy for specific inputs. The only per-input handling
is a small normalization table for flakes with nonstandard export names
(currently just `nur`, whose `modules.nixos`/`modules.homeManager` are
mapped onto the standard conventions); it applies strictly by input name.
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

The host's users are derived from the `homeConfigurations` registry keys —
there is no separate `users` argument. Home configurations are built
separately by `homeConfigurationsBuilder`, but when a `homeConfigurations`
registry is passed here as well, the login bootstrap
(`homeManagerBootstrapModule`) is included automatically. Without a registry
(or without a home-manager input) no bootstrap is added.

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

  # Same registry as homeConfigurationsBuilder; defines the host's users
  # and enables the login bootstrap. Every value is a DIRECTORY with
  # home.nix and/or configuration.nix.
  homeConfigurations = {
    "alice@*"      = ./users/alice;        # on every host
    "alice@laptop" = ./users/alice-laptop; # merged in on laptop
    "bob"          = ./users/bob;          # only when no bob@... matches
  };
}
=>
{ laptop = <nixosSystem>; }
```

Assign the result to your flake's `nixosConfigurations` output, merging
several hosts with `//` — or use `buildNixosConfigurations` to build a
whole set of hosts in one call.

### Type

```
nixosConfigurationsBuilder :: Attribute -> Attribute
```

### Arguments

- **inputs**
  The flake's `inputs` set. Used to auto-discover modules, overlays, lib
  extensions and `nixpkgs-*` variants.

- **hostname**
  The host name; also the key of the returned attrset.

- **system**
  The system double, e.g. `"x86_64-linux"`.

- **nixpkgs**
  The single preferred nixpkgs flake used to build the system. Default `inputs.nixpkgs`.

- **modules**
  Extra NixOS modules, on top of those auto-collected from `inputs` and
  the host's own `hosts/<hostname>(.nix|/configuration.nix)`. Default `[ ]`.

- **additionalModules**
  Further NixOS modules, appended after `modules`. Default `[ ]`.

- **userModuleFn**
  A function `username -> NixOS module`, applied for each user derived from
  `homeConfigurations`. Defaults to `normalUserModule`, which creates a
  normal login account per user; pass your own function for richer
  accounts, or `null` to disable account creation entirely.

- **excludeModuleInputs**
  Input names to skip when auto-collecting NixOS modules. Default `[ ]`.

- **homeConfigurations**
  The registry also passed to `homeConfigurationsBuilder`. Every value
  must be a DIRECTORY containing `home.nix` (the user's home-manager
  config) and/or `configuration.nix` (NixOS config for that user: the
  account, its groups, ...). Companion `configuration.nix` files are
  imported into the system automatically; a directory with only a
  `configuration.nix` is a system-only user (no home output, no login
  bootstrap). Keys select where an entry applies:
    `"<user>@<host>"`  this host only
    `"<user>@*"`       every host; MERGES with a matching `"<user>@<host>"`
    `"<user>"`         standalone default, used only when NO @-entry
                       matched -- never merged with @-entries (a shadowed
                       plain entry triggers an eval warning; import its
                       directory explicitly from an @-entry to reuse it)
  Example: with `"alice@*"` and `"alice@laptop"` both defined, both
  apply on laptop; a plain `"alice"` would then never be used anywhere.
  The keys define the host's users (exposed as `listOfUsernames`); when
  the registry is non-empty and a home-manager input exists the login
  bootstrap is enabled. `null` or `{ }` disables all of it. Default `{ }`.
  WARNING: in a git-backed flake only TRACKED files exist -- `git add` a
  new home.nix/configuration.nix or it is skipped silently.

- **flakeRef**
  Flake reference used by the login bootstrap. Default `inputs.self`.

- **reactivateEveryLogin**
  Bootstrap re-activates on every login instead of only the first. Default `false`.

- **tags**
  List of string tags, passed to modules as the `tags` specialArg.
  `"cudaSupport"` is the one tag with package-set effect (it enables
  `nixpkgs.config.cudaSupport`). Default `[ ]`.

- **patches**
  Patch files applied to the nixpkgs SOURCE tree (via `applyPatches`)
  before the system is evaluated from it. Default `[ ]` (no patching,
  no source copy).

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
  Extra specialArgs merged LAST, overriding anything the builder
  assembled (including `inputs`, `rootPath`, ...). Default `{ }`.

- **systemType**
  Free-form host classification, e.g. `"vm"` or `"server"`. Passed to
  modules as the `systemType` specialArg, and when non-null the host
  config convention looks under `hosts/<systemType>/` instead of
  `hosts/`. Default `null` (no grouping folder).

- **desktopEnvironment**
  Passed to modules as the `desktopEnvironment` specialArg; has no
  effect beyond that. Default `"plasma"`.

- **rootPath**
  The root for the `hosts/<hostname>` convention and the `rootPath`
  specialArg. Default `inputs.self` (the consuming flake).

`homeConfigurationsBuilder` accepts this same shared set, so both
builders can be called with one common argument attrset.




## `lib.nixos.normalUserModule` {#lib.nixos.normalUserModule}

A function from a username to a NixOS module declaring that user as a
normal account whose primary group is a private group named after the
user (the Debian/Fedora "user private group" scheme, instead of NixOS's
shared `users` group) -- so by default a user is only a member of their
own group.

This is the default `userModuleFn` of `nixosConfigurationsBuilder`, so
every user derived from the `homeConfigurations` registry gets a login
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


# strings {#sec-functions-library-strings}


## `lib.strings.stringToTitle` {#lib.strings.stringToTitle}

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


