# Library reference

Generated from the doc comments in `lib/` -- do not edit by hand;
run `nix run .#gen-docs` after changing a doc comment. New to the
builders? Start with the
[getting-started guide](getting-started.md).

## Contents

- [attrsets](#attrsets)
  - [`lib.attrsets.recursiveMerge`](#libattrsetsrecursivemerge)
- [disko](#disko)
  - [`lib.disko.declareZfsRootDisk`](#libdiskodeclarezfsrootdisk)
- [imports](#imports)
  - [`lib.imports.discoverPatches`](#libimportsdiscoverpatches)
  - [`lib.imports.importIfNix`](#libimportsimportifnix)
  - [`lib.imports.importIfNixOr`](#libimportsimportifnixor)
  - [`lib.imports.readIfPlain`](#libimportsreadifplain)
  - [`lib.imports.readIfPlainOr`](#libimportsreadifplainor)
- [nixos](#nixos)
  - [`lib.nixos.buildConfigurations`](#libnixosbuildconfigurations)
  - [`lib.nixos.buildHomeConfigurations`](#libnixosbuildhomeconfigurations)
  - [`lib.nixos.buildNixosConfigurations`](#libnixosbuildnixosconfigurations)
  - [`lib.nixos.discoverUserRegistry`](#libnixosdiscoveruserregistry)
  - [`lib.nixos.homeManagerBootstrapModule`](#libnixoshomemanagerbootstrapmodule)
  - [`lib.nixos.mkHomeConfiguration`](#libnixosmkhomeconfiguration)
  - [`lib.nixos.mkNixosSystem`](#libnixosmknixossystem)
  - [`lib.nixos.normalUserModule`](#libnixosnormalusermodule)
- [strings](#strings)
  - [`lib.strings.stringToTitle`](#libstringsstringtotitle)
- [systemd](#systemd)
  - [`lib.systemd.detachedRun`](#libsystemddetachedrun)
  - [`lib.systemd.interceptingWrapper`](#libsystemdinterceptingwrapper)

# attrsets


## `lib.attrsets.recursiveMerge`

Recursively merge a list of attribute sets.

Merge strategy:
- Single value: use as-is
- All lists: concatenate and deduplicate
- All attrsets: recursively merge
- Mixed types: last value wins (rightmost)

Note that list deduplication only fires when a key occurs in TWO or
more of the merged sets: a key occurring in a single set is taken
verbatim, duplicates inside its list included.

### Type
```
recursiveMerge :: [AttrSet] -> AttrSet
```

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


---

# disko


## `lib.disko.declareZfsRootDisk`

Declare a complete ZFS root disk as a NixOS module: a GPT (GUID
Partition Table) partition layout -- a boot partition (ESP on
x86_64-linux, FIRMWARE + ESP on aarch64-linux), an optional swap
partition, and one partition holding the ZFS pool -- the
`zroot-<hostname>` pool itself, and the standard ZFS datasets inside
it (root, /var, /var/log, /nix/store, /home, optional /tmp) plus one
HOME dataset per user, with optional encryption keyed to the
machine's hardware identity. (A ZFS "pool" is the whole allocated
block of storage; a "dataset" is a mountable sub-filesystem inside
it -- roughly ZFS's equivalent of a partition, but resizable and
nestable.)

Prerequisites: the disko NixOS module must be imported (it provides
the `disko.devices` options -- automatic when disko is a flake input
of a `mkNixosSystem` setup), and ZFS requires `networking.hostId` to
be set (an 8-hex-digit ID ZFS uses to tell "my own pool, imported
normally" apart from "a pool still marked in-use by some OTHER,
possibly still-running machine").

THREAT MODEL: keying the pool to the machine's hardware identity
protects a SEPARATED disk -- pulled for RMA (a warranty
return/replacement), resold, or discarded -- whose new holder does
not also hold the machine. It is near-zero protection against
whole-machine theft: the value is readable from the BIOS setup
screen, chassis stickers and service tags, IPMI (a server's
built-in remote-management interface, readable independently of the
running OS) on `x86_64-linux`, or, on either platform, any live-USB
boot of the very machine holding the disk. This is a deliberate
trade-off: auto-unlock with no TPM (Trusted Platform Module)
involved, not full-disk-encryption-grade secrecy.

RECOVERY: record the hardware identity value somewhere off-machine
at install time -- `dmidecode --string system-uuid` on
`x86_64-linux`, or the `Serial` field of `/proc/cpuinfo` on
`aarch64-linux` (see `keySourceCommand` below for any other
platform). After a hardware swap the pool no longer auto-unlocks,
and boot does NOT prompt for a passphrase either: this function sets
`boot.zfs.requestEncryptionCredentials = [ ]`, opting out of NixOS's
own "prompt for anything still locked" default. Recovery is manual:
boot from a rescue/live medium (a bootable USB/CD running a live
Linux, independent of the installed system), import the pool (ZFS's
term for attaching a pool it doesn't yet know about), and
`zfs load-key -L prompt <dataset>` with the OLD hardware's identity
value as the passphrase, for every affected dataset, then re-key
them to the new hardware's value.

PARTITIONS: one GPT disk, holding (in on-disk order) the boot
partition(s), the ZFS pool partition, then SWAP last if `swapSize` is
nonzero. That order comes from disko's own `priority` field, where a
SMALLER number is created earlier on the disk -- boot gets `1` (`2`
for the second aarch64-linux partition below), the ZFS partition
`10`, SWAP `100`. The ZFS partition's own SIZE is what actually
reserves SWAP's space, despite coming first on disk: with a nonzero
`swapSize` it ends `swapSize` GiB before the end of the disk
(`end = "-${swapSize}G"`), leaving exactly that much free for SWAP to
occupy afterward; with `swapSize = 0` it simply takes the rest of the
disk (`size = "100%"`) and no SWAP partition exists at all. SWAP
itself uses `randomEncryption` -- a fresh random key generated at
every boot, so its content is unrecoverable across reboots by design;
this also means hibernation (suspend-to-disk) is not supported.

The boot partition(s) (skipped entirely by `defineBootPartitions`,
see below) differ by platform, because the firmware that has to find
them differs:

- `x86_64-linux`: one 2 GiB `ESP` partition (GPT type code `EF00`,
  the standard EFI System Partition marker), formatted `vfat`,
  mounted at `/boot` -- what a normal UEFI firmware boots from.
- `aarch64-linux`: TWO 2 GiB `vfat` partitions, both mounted
  ON DEMAND (`noauto` + `x-systemd.automount`, not kept mounted at
  all times): a `FIRMWARE` partition (GPT type code `0700`,
  "Microsoft basic data" -- used here because that is the generic
  FAT marker a Raspberry-Pi-style bootrom scans for, not because it
  is Windows-specific), mounted at `/boot/firmware`, plus a second,
  ordinary `ESP` partition (type `EF00`) mounted at `/boot` for a
  UEFI-capable bootloader (U-Boot, systemd-boot) to chain into once
  the bootrom itself has run. This two-partition layout is shaped
  for Raspberry-Pi-class boards specifically -- a generic aarch64
  UEFI server or VM has no bootrom expecting a `FIRMWARE` partition
  at all, and should pass its own `defineBootPartitions` (typically
  just a single `ESP`, as on `x86_64-linux`) instead of the default.
- any other platform has no predefined layout at all and THROWS
  unless `defineBootPartitions` is given.

`defineBootPartitions` (see Arguments below) replaces this whole
dispatch with an attrset of partition definitions of your own, valid
on any platform -- use it to change the predefined layout above, or
to support a platform this function does not predefine one for. A
further opt-in argument, `legacyBoot`, splices an ADDITION into (not a
replacement of) the predefined layout above, so it throws if combined
with `defineBootPartitions` -- there is nothing predefined left to
splice into. It is ONE argument, valid on both predefined platforms,
but NOT one mechanism: despite both existing to support a "legacy"
boot path, `legacyBoot` does two unrelated things for two unrelated
firmwares, chosen by platform:

- `aarch64-linux`: registers the `FIRMWARE` partition as ALSO an
  entry in a hybrid MBR table (disko's own native mechanism,
  `sgdisk -h` under the hood) -- for a Raspberry-Pi-style bootrom,
  which cannot read GPT at all and instead reads the MBR partition
  table directly to find its FAT boot partition.
- `x86_64-linux`: adds a third, raw 1 MiB `EF02` partition (no
  filesystem, never mounted) before `ESP` -- GRUB's own BIOS+GPT boot
  mechanism, which finds this partition by its type code and embeds
  its boot code directly into it. Unlike the aarch64-linux behavior,
  this never touches the MBR partition table at all; GRUB reads GPT
  normally once its embedded code has run.

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
  The key is derived from the machine's hardware identity: on
  `x86_64-linux`, `dmidecode --string system-uuid`; on
  `aarch64-linux`, the `Serial` field of `/proc/cpuinfo`. Record the
  relevant one off-machine; see the THREAT MODEL and RECOVERY
  paragraphs above for what this protects against and what a
  hardware swap costs. See `keySourceCommand` below to use a
  different source, or to support another platform.

- **swapSize**
  Set the size (in GiB, gibibytes -- 1024^3 bytes) of the SWAP
  partition. Default is `32`.
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

- **legacyBoot**
  One argument, valid on both `aarch64-linux` and `x86_64-linux`, but
  NOT one mechanism: on `aarch64-linux` it registers the `FIRMWARE`
  partition in a hybrid MBR table, for a Raspberry-Pi-style bootrom
  that cannot read GPT at all; on `x86_64-linux` it adds a raw `EF02`
  partition for GRUB's BIOS+GPT boot embedding instead -- see the
  PARTITIONS section above for why these are unrelated mechanisms
  sharing one flag rather than one shared implementation. Throws if
  combined with `defineBootPartitions`, or on any other platform.
  Default `false`.

- **keySourceCommand**
  Overrides where the encryption key comes from. Default `null` (use
  the predefined per-platform source described under
  `enableEncryption` above: `dmidecode` on `x86_64-linux`,
  `/proc/cpuinfo`'s `Serial` on `aarch64-linux`). A string replaces
  that dispatch entirely, on ANY platform: a POSIX-sh snippet (no
  `[[`, no `$'...'` -- it may run under busybox ash, in the
  script-initrd context) that sets the shell variable `KEY` to the
  key material. Use it to support a platform with no predefined
  source, or to key the pool to something other than this function's
  default choice. `enableEncryption = true` on a platform that is
  neither `x86_64-linux` nor `aarch64-linux` throws unless this is
  given -- there is no predefined source to fall back to.

- **extraDatasets**
  An attribute set of additional zfs datasets, merged into the generated ones.
  Keys are dataset paths relative to the pool root (like the generated
  `ROOT/NixOS` or `HOME/<username>`), values are disko dataset definitions.
  Parent datasets are not created implicitly -- declare them too.
  Merged last, so it can also override a generated dataset.
  Example: { "DATA" = { type = "zfs_fs"; options.mountpoint = "none"; };
             "DATA/media" = { type = "zfs_fs"; mountpoint = "/srv/media"; options.mountpoint = "legacy"; }; }


---

# imports


## `lib.imports.discoverPatches`

Auto-discover a directory of nixpkgs patches, classified by filename,
for the builders' `patches` argument (fed to `pkgs.applyPatches` --
see `mkNixosSystem`'s doc comment). Returns a plain list.

You will usually NOT call this directly: a `patches` list element
that is a directory auto-expands through it already (see
`mkNixosSystem`'s `patches` argument) -- `patches = [ ./patches ];`
is enough, mixed with explicit `.patch` paths or derivations if
wanted. Call it yourself only for something the builder's own
expansion cannot do, e.g. filtering the discovered list before use:
`patches = builtins.filter keep (discoverPatches pkgs ./patches);`.

| Filename                                  | Effect |
| ------------------------------------------ | ------ |
| `<name>.patch`                             | A local unified-diff patch, used as-is. |
| `<name>.nix`                               | A REMOTE patch: the file must evaluate to a function `pkgs: <derivation>` -- the common form is `pkgs.fetchpatch { url = ...; hash = ...; }` against an upstream PR's `.diff` URL. Called with `pkgs`, and the resulting derivation is used as the patch. |
| anything ending in `.disabled`             | Ignored, no warning -- e.g. `<name>.patch.disabled` or `<name>.nix.disabled` keeps a known-good copy around without deleting it or applying it. |
| `*.md`                                     | Ignored, no warning -- documentation (a README explaining the convention, say). |
| anything else                              | Ignored, WITH an evaluation warning naming the exact file -- a skipped file is never a silent mystery. |

A stray subdirectory, or a symlink to one, is treated the same as an
unrecognized filename: warned and skipped. A symlink to a REGULAR file
is resolved and classified by what it points at, same rule as
`importIfNixOr`/`readIfPlainOr` -- so a symlinked `.patch`/`.nix` file
is picked up like its target. A DANGLING symlink is not specially
detected (Nix has no cheap, non-crashing way to tell "broken link"
apart from "links to a regular file" -- see the code comment on
`resolvedType`): it is treated as regular and only fails once the
patch is actually used, as a plain Nix error naming the missing path
rather than a warning naming the symlink.

Applied in LEXICOGRAPHIC filename order (`builtins.readDir`'s own
ordering) -- `.patch` and `.nix` entries interleave by name, so prefix
filenames with `10-`, `50-`, `99-`, etc. when application order
matters.

A missing directory is NOT an error: it is treated the same as an
empty one (`[ ]`) -- a repo with no patches at all should not need to
create an empty directory just to call this.

### Example

```nix
# the usual way -- no call needed, the builder expands the directory itself
patches = [ ./patches ];

# calling it directly, only needed for something the builder's own
# expansion cannot do, e.g. filtering:
# extLib = inputs.nixpkgs-lib-extensions.lib
patches = builtins.filter (p: builtins.baseNameOf (toString p) != "flaky.patch") (
  extLib.discoverPatches pkgs ./patches
);
```

```
patches/
  10-foundational.patch
  50-feature.nix              # pkgs: pkgs.fetchpatch { url = ...; hash = ...; }
  99-cleanup.patch.disabled   # ignored
  README.md                  # ignored
  notes.txt                  # WARNS: unrecognized filename
```

### Type

```
discoverPatches :: pkgs -> Path -> [ Path | Derivation ]
```

### Arguments

- **pkgs**
  The package set passed to each `.nix` remote-patch file (`import file pkgs`).

- **dir**
  The directory to scan. Non-existent is treated as empty, not an error.




## `lib.imports.importIfNix`

Import a path only when it contains valid, importable Nix; otherwise
return `{ }` (a harmless no-op module) with a warning naming the
reason. Exactly `importIfNixOr` with the default fixed to `{ }` -- see
that function for the full semantics; use it directly to provide your
own fallback value.

Because the fallback is always the plain attrset `{ }`, this function
is for module-shaped or plain-attrset content only -- fine for
`imports = [ (extLib.importIfNix pkgs ./private.nix) ]`, where the
module system applies whatever comes back either way. If `path` is
expected to be a FUNCTION you call yourself, `{ }` is not callable and
that call throws on the fallback branch; use `importIfNixOr` instead,
with a `default` shaped to match.

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

The import is BARE -- `import path`, nothing applied. Dropped into a
NixOS/home-manager module's `imports` list, that is exactly what you
want: if `path`'s content is a module FUNCTION
(`{ config, pkgs, lib, ... }: { ... }`), the module system applies it
itself and already supplies `config`/`pkgs`/`lib` plus any specialArgs
the builders wire in (`inputs`, `extLib`, `rootPath`, ...) -- no extra
plumbing needed here. Calling the RESULT yourself instead (outside a
module context) needs `default` to match the shape `path` is expected
to have -- see `default` below.

Made for setups where secret files are encrypted in the remote repo
(e.g. via git-crypt -- see `readIfPlainOr`'s doc comment for what it
does to a checkout without the decryption key): locally `private.nix`
is plain Nix and gets imported;
on a CI checkout the same path is an encrypted blob, which fails the
validity probe and becomes the (non-secret) default -- so the same
configuration evaluates in both places.

Accepted: a regular file with the `.nix` suffix whose content parses as
Nix, or a directory whose `default.nix` does. Symlinks are followed
and classified by what they resolve to (a link to a valid `.nix` file
imports like its target; a dangling link counts as missing).
Everything else yields
`default` WITH an evaluation warning naming the reason (missing path,
unsupported file extension, directory without default.nix, or content
that is not valid Nix) -- a skipped import is never a silent mystery.
When scanning directories, filter names by the `.nix` suffix first so
intentionally skipped files do not warn.

Content validity cannot be checked in pure evaluation (a parse error
from `import` is uncatchable, and `builtins.readFile` refuses binary
files), so the probe runs `nix-instantiate --parse` in a small
derivation -- import-from-derivation, built during evaluation on the
machine doing the evaluating (`preferLocalBuild`, no substitution),
and cached per file content. IFD is REQUIRED: any evaluation using
`importIfNix`/`importIfNixOr` fails under
`--no-allow-import-from-derivation` (the builders' `patches`
argument shares this constraint).

Only an actual parse REJECTION counts as invalid content: when
nix-instantiate fails for any other reason (a crash, a killed
process), the function THROWS instead of quietly returning `default`
-- that is a broken probe, not an encrypted file. If the probe
derivation itself fails to build, evaluation aborts with that build
error (IFD cannot continue past it). And the verdict comes from the
`pkgs.nix` parser rather than the evaluating Nix, so a parser-version
skew between the two can (rarely) let a file pass the probe and still
fail the actual `import`, or reject what the evaluator would accept.

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
  If you plan to CALL the resolved value yourself (rather than let a
  module system apply it), give `default` the SAME shape as what a
  valid `path` would produce -- e.g. a function of the same arity --
  so applying arguments works the same way whether the valid or the
  fallback branch fired. Mismatched shapes only fail on the fallback
  path, so this can look fine locally and break only on CI, where the
  encrypted file actually takes that branch.




## `lib.imports.readIfPlain`

Read a path as plain text only when it is not still git-crypt
ciphertext; otherwise return `""` with a warning naming the reason.
Exactly `readIfPlainOr` with the default fixed to `""` -- see that
function for the full semantics; use it directly to provide your own
fallback value (e.g. when an empty string is itself a meaningful,
ambiguous result).

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
# CI-safe secrets: locally read, an
# encrypted blob on CI becomes ""
services.foo.apiToken = extLib.readIfPlain pkgs ./token.txt;
```

### Type

```
readIfPlain :: pkgs -> Path -> String
```

### Arguments

- **pkgs**
  A package set used to build the header-check probe (IFD).

- **path**
  The path (or absolute path string) to inspect and maybe read.




## `lib.imports.readIfPlainOr`

Read a path as plain text, but only when it is NOT still git-crypt
ciphertext; otherwise return `default` instead of aborting evaluation.
`readIfPlain` is the same function with the default fixed to `""`.

Companion to `importIfNixOr`/`importIfNix` for files that are not Nix
-- a plain secret, token, or config value protected by git-crypt
(which encrypts individual files in a git repo transparently -- a
checkout without the decryption key sees raw ciphertext instead of
the file's real content). Locally (key present) git-crypt's smudge
filter has already replaced the working-tree file with real
plaintext, and this returns it as a string. On a checkout without the
key, the working-tree file is still git-crypt's raw ciphertext --
`builtins.readFile` on that would likely THROW (its bytes are not
valid UTF-8) rather than return usable garbage, so the ciphertext is
detected BEFORE ever calling `readFile` on it.

Detection does not depend on the plaintext's content being valid Nix
(there may be none to parse): a git-crypt-encrypted file always
begins with the same fixed 10-byte header (a NUL byte, `GITCRYPT`,
another NUL byte), whatever the plaintext underneath actually is.
That header is checked byte-for-byte in a small derivation
(import-from-derivation, `preferLocalBuild`) -- IFD, like
`importIfNixOr`'s parse probe, just testing a fixed magic value
instead of running a Nix parser.

Accepted: a regular file whose first bytes are not that header.
Symlinks are followed and classified by what they resolve to (a link
to such a file reads like its target; a dangling link counts as
missing). Everything else -- a missing path, a directory, or
genuine git-crypt ciphertext -- yields `default` WITH an evaluation
warning naming the reason, so a skipped read is never a silent
mystery.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
extLib.readIfPlainOr pkgs ./api-token.txt ""
# locally (key present)    => "sk-abc123...\n"
# on CI (still encrypted)  => "" (warns)
```

### Type

```
readIfPlainOr :: pkgs -> Path -> String -> String
```

### Arguments

- **pkgs**
  A package set used to build the header-check probe (IFD).

- **path**
  The path (or absolute path string) to inspect and maybe read.

- **default**
  The value returned (with a warning) when `path` is still
  git-crypt ciphertext, missing, or not a regular file.


---

# nixos


## `lib.nixos.buildConfigurations`

Build a whole flake's `nixosConfigurations` AND `homeConfigurations`
from ONE hosts attrset, in one call — the entry point most consuming
flakes want.

`buildNixosConfigurations` and `buildHomeConfigurations` produce the
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

### Example

```nix
# a complete flake outputs function:
# extLib = inputs.nixpkgs-lib-extensions.lib
outputs =
  { nixpkgs-lib-extensions, ... }@inputs:
  nixpkgs-lib-extensions.lib.buildConfigurations {
    _defaults = {
      inherit inputs;
      system = "x86_64-linux";
      userRegistry."alice" = ./users/alice;
      loginHomes = [ "alice" ];
    };
    laptop = { };
    server = { userRegistry = { }; };
  };
=>
{
  nixosConfigurations = { laptop = <nixosSystem>; server = <nixosSystem>; };
  homeConfigurations = { "alice@laptop" = <homeManagerConfiguration>; };
}
```

### Type

```
buildConfigurations ::
  { <hostname> = Attribute; }
  -> { nixosConfigurations = { <hostname> = NixosSystem; };
       homeConfigurations = { "<user>@<hostname>" = HomeManagerConfiguration; }; }
```

### Arguments

- **hosts**
  The same attrset `buildNixosConfigurations` and
  `buildHomeConfigurations` accept — same allowlists, same `_defaults`
  semantics. See `buildNixosConfigurations` for the full key reference.




## `lib.nixos.buildHomeConfigurations`

Build the standalone home-manager configurations of every host's
LOGIN-managed users in one call: takes the SAME hosts attrset as
`buildNixosConfigurations` (including `_defaults` and the allowlist
validation), applies `mkHomeConfiguration` per login user, and
merges everything into one `{ "<user>@<hostname>" = ...; }` set —
assignable to a flake's `homeConfigurations` output directly.

Only users listed in `loginHomes` (and shipping a `home.nix` for the
host) get an output: SYSTEM-managed homes -- the default for anyone
not in `loginHomes`, built into the NixOS system itself rather than
activated at login; see `mkNixosSystem` for the full contrast -- are
part of the systems built by `buildNixosConfigurations` and need no
flake output. The
produced set is exactly what the login bootstrap activates
(`home-manager switch --flake <loginFlakeRef>#<user>@<host>`):

```nix
let
  hosts = {
    _defaults = {
      inherit inputs system userRegistry;
      loginHomes = [ "alice" ];
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

NixOS-only arguments in the attrset (`modules`, `userModule`, ...)
are accepted and ignored here, so one hosts attrset can feed both
build functions (`homeModules` applies on BOTH sides: to the
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
    loginHomes = [ "alice" ];
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
`mkNixosSystem` to every value of `hosts`, with the
attribute key as the hostname. The result has the same keys, so it can
be assigned to a flake's `nixosConfigurations` output directly.
Duplicate hostnames are impossible by construction (attrset keys are
unique); an entry that also sets a *conflicting* inner `hostname`
throws.

The reserved key `_defaults` (never a hostname -- a hostname cannot
START with `_`) provides arguments for every host. Merging is
per-argument and a host entry wins entirely: no deep-merging of lists
or attrsets. For "shared base plus per-host extras" put the addition in
that host's `extra` slot instead -- ONE rule for every argument: a bare
key REPLACES the default, `extra.<key>` ADDS to it (lists concatenate,
attrsets merge with `extra` winning a conflict).

A second reserved key, `_groups`, holds OPTIONAL per-group defaults: a
host declaring `group = "<name>";` receives `_groups.<name>` merged
BETWEEN `_defaults` and its own entry, later layers winning per
argument. Each group entry takes the same argument names as
`_defaults` plus an `extra` slot that ADDS to the `_defaults` values
(same rule as a host's `extra`); it cannot set `group` itself -- its
attribute name IS the group. When `_groups` is present, every host's
`group` must name one of its entries (unknown names throw); without
`_groups`, `group` is the free-form classification it always was.

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
    # ADDS to _defaults.modules instead of replacing it
    extra.modules = [ ./common/laptop-extras.nix ];
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
  Attribute set mapping hostnames to `mkNixosSystem`
  argument sets. The key provides `hostname`, so entries do not set
  it themselves. Host entry keys are checked against the same
  allowlist as `_defaults` plus the per-host-only keys (`extra`, and a
  redundant `hostname` equal to the attribute key); anything else
  throws, so typos and leftover arguments fail loudly. `extra` accepts
  the same argument names, and its keys are checked the same way.

- **_defaults**
  Optional reserved entry of `hosts` (never a hostname): arguments
  merged under every host entry, the host winning per argument. Can
  provide a default for every `mkNixosSystem` argument
  except the per-host ones:
  
  - `inputs`
  - `system`
  - `nixpkgs`
  - `rootPath`
  - `modules`
  - `userModule`
  - `userRegistry`
  - `loginHomes`
  - `homeModules` (applies to BOTH mechanisms: system-managed
    homes here, login-managed homes in `buildHomeConfigurations`)
  - `loginFlakeRef`
  - `loginReactivateEveryLogin`
  - `traceDiscoveredUsers`
  - `tags`
  - `group` (also selects the host's `_groups` layer)
  - `hostFolder`
  - `patches`
  - `overlays`
  - `allowedUnfreePackages`
  - `permittedInsecurePackages`
  - `nixpkgsConfig`
  - `specialArgs`
  - `homeManager`
  - `inputContributions`
  
  This list is an enforced ALLOWLIST: any other key throws, so typos
  (`homeConfiguration`, ...) fail loudly instead of being dropped
  silently. `hostname` (it comes from each attribute key) and `extra`
  (per-host only) get their own explanatory errors.

- **_groups**
  Optional reserved entry of `hosts` (never a hostname): per-group
  argument sets, applied between `_defaults` and the host entries
  that declare the matching `group` -- see the description above.




## `lib.nixos.discoverUserRegistry`

Auto-discover a `userRegistry` from a `users/` directory: one
`"<name>@*"` entry per subdirectory that looks like a registry entry.
You will usually NOT call this directly -- `mkNixosSystem`'s own
`userRegistry` argument already does this automatically when it is
omitted and `loginFlakeRef` names a flake input (see its doc comment).
Call it yourself only for something that convention cannot do: scanning
a differently-named directory, or filtering/extending the result before
use (`discoverUserRegistry dir // { "extra@*" = ./local-user; }`).

| Entry in `dir`                                          | Effect |
| -------------------------------------------------------- | ------ |
| subdirectory with `home.nix` and/or `configuration.nix`   | becomes `"<name>@*" = <path>;` |
| subdirectory with NEITHER file                            | ignored, WITH a warning naming the directory -- a scan guessed wrong, so it degrades to a warning rather than the throw a hand-written registry entry with the same problem gets |
| a dotfile or dot-directory (`.gitkeep`, `.git`, ...)      | ignored, no warning |
| anything else (a plain file, `README.md`, ...)            | ignored, no warning -- only a directory could ever be a registry entry, so a stray file is not a mistake worth flagging |

A symlink is resolved and classified by what it points at, same rule as
`discoverPatches`/`importIfNixOr`. A missing `dir` is not an error: it
is treated the same as an empty one (`{ }`) -- most flakes have no
`users/` directory at all. Likewise if `dir` cannot be read under pure
evaluation at all (`mkNixosSystem`'s auto-discovery -- see its own doc
comment -- calls this on whatever `loginFlakeRef`/`inputs.self` happens
to be, even for a caller who never set either up for this).

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
extLib.discoverUserRegistry (inputs.home-manager-config + "/users")
=> { "dennis@*" = <path to .../users/dennis>; "root@*" = <path to .../users/root>; }
```

### Type

```
discoverUserRegistry :: Path -> Attribute
```

### Arguments

- **dir**
  The users directory to scan. Non-existent is treated as empty, not an error.




## `lib.nixos.homeManagerBootstrapModule`

A NixOS module that provisions each user's standalone home-manager profile on
login, via a systemd *user* service that runs `home-manager switch` in the
background (so login is never hard-blocked). First-login-only by default.

`mkNixosSystem` includes this module automatically when it
has `loginHomes`, so it normally does not need to be wired up by hand —
direct use is for custom setups that build their NixOS systems some
other way. It is driven by the `userRegistry` filtered by `loginHomes`
(the same arguments the builders take) but is otherwise independent of
the builders. Self-gating: when no login user matches, the home-manager
input is missing or the flake reference is unset, the module is empty.

### Example

```nix
# Only needed when NOT using mkNixosSystem:
# extLib = inputs.nixpkgs-lib-extensions.lib
{
  imports = [
    (extLib.homeManagerBootstrapModule {
      inherit inputs;
      hostname = "laptop";
      system   = "x86_64-linux";
      userRegistry = { "alice" = ./users/alice; };
      loginHomes = [ "alice" ];
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
  The user registry (as in `mkNixosSystem`). Default `{ }`.

- **loginHomes**
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




## `lib.nixos.mkHomeConfiguration`

Build ONE user's standalone home-manager configuration for one host —
the single-user primitive underneath `buildHomeConfigurations`, which
calls it for every login-managed user of every host. Use it directly
to export an individual home:

```nix
homeConfigurations."alice@laptop" =
  extLib.mkHomeConfiguration {
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
`mkNixosSystem`. Shares the package set, `specialArgs`
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
extLib.mkHomeConfiguration {
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
mkHomeConfiguration :: Attribute -> HomeManagerConfiguration
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
  The user registry (same shape as in `mkNixosSystem`);
  only the entries matching `username` on `hostname` are used here.
  Default `{ }`.
  NOTE: in a git-backed flake, `git add` new files or they are
  invisible to the flake and skipped silently.

- **homeModules**
  home-manager modules added to the home configuration, on top of those
  auto-collected from `inputs`. Default `[ ]`.

The home configuration gets overridable (`mkDefault`) values for
`home.username` (the user) and `home.homeDirectory` (`/home/<user>`).
`home.stateVersion` gets a similar convenience default, but at a
WEAKER priority than `mkDefault` -- so a consumer's own `mkDefault`
pin in `home.nix` wins outright instead of colliding with the
builder's default at equal priority -- and it tracks the CURRENT
nixpkgs release, with a WARNING for any home actually relying on
that moving default, naming the two pin recipes: the user's own
`home.nix`, or fleet-wide via a shared `homeModules` entry.

- **nixpkgs, group, specialArgs, tags, patches, nixpkgsConfig, overlays, allowedUnfreePackages, permittedInsecurePackages, rootPath, homeManager, inputContributions**
  Shared options (see `mkNixosSystem`).




## `lib.nixos.mkNixosSystem`

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
  guess, naming the selections that resolve it -- see
  `inputContributions`, which also narrows a channel (this doc's term
  for an export KIND: `nixosModules`/`homeModules`/`overlays`/
  `libOverlays`/`lib` -- unrelated to the `nixpkgsLibExtensions.channels`
  package-set option further below, which reuses the same word for a
  different thing) to named entries or switches it off.
- overlays from any input exposing `overlays.default` (same
  default/sole-entry rule, but no exclusions -- overlays are collected
  from every input, nixpkgs trees included).
- lib extensions from any input exposing a lib overlay
  `libOverlays.default = final: prev: { ... };` -- it composes through
  `lib.extend`, so one addition can reference another via `final`.
  This repo's own extensions are always applied to the system `lib`
  and also passed as the `extLib` specialArg. Governed by the
  `libOverlays` channel of `inputContributions`.
- each input's standalone `lib` export, namespaced by input name:
  `lib.<inputName>` in modules and `pkgs.lib.<inputName>` (e.g.
  `lib.NixVirt.domain`). Never merged flat -- a lib overlay is the
  composable way into the flat lib -- and never overwriting: if the
  name is a namespace this repo owns (`disko`, ...) the input's lib is
  MERGED into it with the existing side winning every conflict (so a
  `disko` input's helpers join `declareZfsRootDisk` under `lib.disko`);
  any other existing name is skipped with a warning, and nixpkgs trees
  are not namespaced at all (their lib is the base). The consuming
  flake's own `lib` output (`inputs.self`) is renamed to `lib.flake`
  -- export your helper functions there and every module gets them as
  `lib.flake.<helper>` with zero wiring.
- every `nixpkgs-*` input as a package set under the
  `nixpkgsLibExtensions.channels.<variant>` option (an unrelated reuse
  of the word "channel" from the export-KIND sense above -- this one
  names a package-set variant, not a kind of export) (e.g.
  `inputs.nixpkgs-unstable` becomes
  `config.nixpkgsLibExtensions.channels.unstable`), built with the same
  overlays and config as the primary `pkgs`.

The whole `inputs` set is also passed through as the `inputs` specialArg
(and home-manager extraSpecialArg), so modules can reach anything not
covered by those conventions (e.g. `inputs.fenix`) themselves — the
builders carry no policy for specific inputs. The only per-input hook
is a normalization table for flakes with nonstandard export names,
applied strictly by input name -- currently empty (NUR, the Nix User
Repository, was its one former entry; it now contributes via
`overlays.default` like any other input).
As a convenience, `nixpkgsLibExtensions.inputPkgs` holds every input's
packages pre-selected for the host's system
(`config.nixpkgsLibExtensions.inputPkgs.disko.disko-install`); they are
deliberately not merged into `pkgs`, where input names would shadow
nixpkgs attributes.

The builder-derived per-host values are declared as options under
`nixpkgsLibExtensions.*` in every NixOS module set AND every home
(whichever mechanism built it): `tags` (mergeable), `group`,
`users`, `inputPkgs` and `channels` (read-only), plus `hostname` in
homes only -- NixOS modules read `config.networking.hostName`, which
the builder sets.

The host's own configuration is included by convention: relative to
`rootPath` (default: the consuming flake, `inputs.self`), either
`hosts/<hostname>.nix` or `hosts/<hostname>/configuration.nix` is
imported automatically when it exists (both existing is an error).
Setting `group` groups hosts one folder deeper: the lookup then
happens under `hosts/<group>/` instead of `hosts/` (`hostFolder`
overrides the folder segment without touching the classification).

The host's users come from ONE `userRegistry` — every user gets an
account (unless `userModule = null`, or the account is a system one
with a uid below 1000) and their `configuration.nix` imported into
the system. How
each user's `home.nix` is activated is selected by `loginHomes`:

- not listed (the default) — SYSTEM-managed home: wired into the
  system via home-manager's NixOS module
  (`home-manager.users.<user>`), activated by `nixos-rebuild
  switch`. No flake outputs, no bootstrap.
- listed in `loginHomes` — LOGIN-managed home: activated on first
  login by the bootstrap (`homeManagerBootstrapModule`) running
  `home-manager switch --flake <loginFlakeRef>#<user>@<host>`; the
  flake must export those `homeConfigurations` outputs (built by
  `buildHomeConfigurations` from the same hosts attrset).

A home is managed by exactly one mechanism, by construction.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
extLib.mkNixosSystem {
  inherit inputs;
  hostname = "laptop";
  system   = "x86_64-linux";
  nixpkgs  = inputs.nixpkgs;
  # ./hosts/laptop.nix (or ./hosts/laptop/configuration.nix) is
  # imported automatically; `modules` is only for anything extra.

  # ALL users: accounts + configuration.nix, and home.nix activated
  # with the system (home-manager NixOS module) unless listed in
  # loginHomes. Every value is a DIRECTORY with home.nix and/or
  # configuration.nix.
  userRegistry = {
    "alice@*"      = ./users/alice;        # on every host
    "alice@laptop" = ./users/alice-laptop; # merged in on laptop
    "bob"          = ./users/bob;          # only when no bob@... matches
  };
  # bob's home.nix activates on his first login instead (needs the
  # homeConfigurations outputs from buildHomeConfigurations)
  loginHomes = [ "bob" ];
}
=>
<nixosSystem>
```

The system is returned BARE (like `mkHomeConfiguration`), so
assign it to your flake's `nixosConfigurations` output under an
explicit key, e.g.
`nixosConfigurations.laptop = extLib.mkNixosSystem { ... }`
— or use `buildNixosConfigurations` to build a whole keyed set of
hosts in one call.

### Type

```
mkNixosSystem :: Attribute -> NixosSystem
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
  In a hosts attrset, a host adds to the shared list with
  `extra.modules = [ ... ];` rather than replacing it.

- **userModule**
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
  CURRENT nixpkgs release, with a WARNING for any home relying on
  that moving default -- pin it in the user's `home.nix` or fleet-wide
  via `homeModules` -- and receives `username` as a module
  argument) -- unless the user is listed in `loginHomes`. Prefer
  path values over absolute path strings: a CONTEXT-FREE string escapes
  the flake (never copied to the store, fails under pure evaluation)
  and warns. A string built by concatenating onto a flake INPUT
  (`inputs.foo + "/users/alice"`) is not the same hazard -- it carries
  store context and is pure-eval-safe -- and is accepted without
  warning. A directory with only a `configuration.nix` is a system-only user
  (account, no home). Keys select where an entry applies:
    `"<user>@<host>"`  this host only
    `"<user>@*"`       every host; MERGES with a matching `"<user>@<host>"`
    `"<user>"`         standalone default, used only when NO @-entry
                       matched -- never merged with @-entries (a shadowed
                       plain entry triggers an eval warning; import its
                       directory explicitly from an @-entry to reuse it)
  Example: with `"alice@*"` and `"alice@laptop"` both defined, both
  apply on laptop; a plain `"alice"` would then never be used anywhere.
  A `"<user>@*"` entry's directory is ALSO scanned for a
  `hosts/<hostname>` subdirectory -- the SAME convention
  `hosts/<hostname>.nix` uses at the flake root, one level down -- and
  merges it in exactly like an explicit `"<user>@<hostname>"` entry
  would. An explicit `"<user>@<hostname>"` key and an auto-detected
  `hosts/<hostname>` folder both existing for the same user+host is
  ambiguous and THROWS, naming both paths.
  The keys define the host's users (exposed as the
  `nixpkgsLibExtensions.users` option).
  `null` or `{ }` disables it.
  OMITTED ENTIRELY (not `null`, not `{ }` -- genuinely absent), it
  auto-discovers instead: when `loginFlakeRef` resolves to a flake
  input, every subdirectory of that input's `users/` directory shipping
  `home.nix`/`configuration.nix` becomes a `"<name>@*"` entry (see
  `discoverUserRegistry`). A `loginFlakeRef` flake-ref STRING (a
  mutable checkout, not an input) cannot be read this way -- those
  setups still write `userRegistry` explicitly. Adoption is announced
  per host via `traceDiscoveredUsers` (default `true`); set
  `userRegistry = { };` to disable discovery outright.
  WARNING: in a git-backed flake only TRACKED files exist -- `git add` a
  new home.nix/configuration.nix or it is skipped silently.

- **loginHomes**
  List of usernames (from `userRegistry`) whose `home.nix` is
  LOGIN-managed instead of system-managed: not part of the system,
  activated on the user's first login by the bootstrap via
  `home-manager switch --flake <loginFlakeRef>#<user>@<host>` -- the
  flake must export those `homeConfigurations` outputs (built by
  `buildHomeConfigurations` from the same hosts attrset). Accounts
  and `configuration.nix` handling are unaffected. Names not
  matching any of this host's users are ignored in a DIRECT call
  like this (the list is usually shared through `_defaults` across
  hosts, so "not on this host" is normal) -- but the hosts-attrset
  builders see every host at once, and a name that matches no
  registry user on ANY host is a typo and THROWS there. Default
  `[ ]` (every home is system-managed).

- **loginFlakeRef**
  Where the login bootstrap finds the home configurations of
  `loginHomes` users: on first login it runs
  `home-manager switch --flake <loginFlakeRef>#<user>@<hostname>`, so the
  flake at this reference must export
  `homeConfigurations."<user>@<hostname>"`.
  The default `inputs.self` is the IMMUTABLE store copy of your flake
  that the running system was built from -- homes then always match
  the last `nixos-rebuild`, but local edits are invisible until the
  next rebuild. Point it at a mutable checkout (e.g. `"/etc/nixos"`
  or `"git+https://..."`) to make the bootstrap build from the live
  tree instead -- a real, supported capability (not eval-time
  knowable, so `userRegistry` auto-discovery never applies to it;
  passing one WARNS, naming the trade-off, not because it is wrong).
  Irrelevant without `loginHomes` users.
  Default `inputs.self`.

- **traceDiscoveredUsers**
  Whether `userRegistry` auto-discovery (see its own entry above)
  announces what it adopted: `host \`<name>\`: userRegistry
  auto-discovered from <ref>/users: <names>`, once per host that
  actually adopted one (never printed for a host that supplies its own
  `userRegistry`, or whose scan found nothing). May print more than
  once per host -- the registry is independently resolved at each of
  several internal call sites, and Nix has no way to deduplicate a
  trace across them. Default `true`.

- **loginReactivateEveryLogin**
  Bootstrap re-activates on every login instead of only the first.
  Irrelevant without `loginHomes` users. Default `false`.

- **homeModules**
  home-manager modules added to every SYSTEM-managed home (on top of
  those auto-collected from `inputs`). The same argument is read by
  `mkHomeConfiguration`/`buildHomeConfigurations` for the
  login-managed homes, so in a shared hosts attrset it applies to
  both kinds. Default `[ ]`.

- **tags**
  List of string tags, seeding the `nixpkgsLibExtensions.tags` option
  -- modules can ADD tags by defining that option, and the list
  definitions merge. The merged value is set as `system.nixos.tags`
  (mkDefault) so tags label the host's boot-menu entries; a host
  defining that option itself overrides this. Tags carry no other
  behavior. Default `[ ]`.

- **nixpkgsConfig**
  Attribute set merged into `nixpkgs.config` for the host's package
  set -- e.g. `{ cudaSupport = true; }`. Merged last, so it can also
  override what `allowedUnfreePackages`/`permittedInsecurePackages`
  produced. This is the ONLY route for nixpkgs config here: the builder
  passes a package set it built itself, and nixpkgs asserts that the
  `nixpkgs.config` module option is empty in that case ("nixpkgs.config
  options should be passed when creating the instance instead"). Setting
  it from a module therefore fails an assertion rather than being
  ignored. Default `{ }`.

- **patches**
  Patch files applied to the nixpkgs SOURCE tree (via `applyPatches`)
  before the system is evaluated from it. Default `[ ]` (no patching,
  no source copy). A non-empty list requires import-from-derivation:
  the patched tree is BUILT during evaluation, so that host fails
  under `--no-allow-import-from-derivation` (and eval-only workflows
  like `nix flake check --no-build` stop working for it). See
  [Patching nixpkgs itself](getting-started.md#patching-nixpkgs-itself)
  for an example and the costs involved.
  A list element that is a directory auto-expands via `discoverPatches`
  -- `patches = [ ./patches ];` works directly, mixed with explicit
  `.patch` paths or derivations if wanted. See `discoverPatches`'s own
  doc comment for the directory's file-classification rules.

- **overlays**
  Overlays applied on top of the ones auto-collected from `inputs`.
  Unlike `nixpkgsConfig`, this is not the only route: a
  module's own `nixpkgs.overlays` works too and composes with these
  (nixpkgs appends module overlays onto the package set passed in),
  so a third-party module bringing its own overlays needs nothing
  special. Prefer this argument when you want explicit ordering or
  want the overlay in the package set the builder shares with
  home-manager. Default `[ ]`.

- **allowedUnfreePackages**
  Unfree package names to allow (matched by `lib.getName` via
  `allowUnfreePredicate`) -- a shorthand for the `nixpkgsConfig`
  recipe `nixpkgsConfig.allowUnfreePredicate = pkg:
  builtins.elem (lib.getName pkg) [ ... ];`, which is the canonical
  path when you need anything beyond a name list. Default `[ ]`.

- **permittedInsecurePackages**
  Passed through to `nixpkgs.config.permittedInsecurePackages` -- a
  shorthand for the `nixpkgsConfig` recipe
  `nixpkgsConfig.permittedInsecurePackages = [ ... ];`. Default `[ ]`.

- **specialArgs**
  Extra specialArgs, merged alongside the ones the builder assembles
  (`inputs`, `rootPath`, `extLib`). Redefining
  a builder-owned name THROWS: overriding one changed only what
  modules see, not what the builder did. The option-backed names
  (`hostname`, `tags`, `group`, `users`, `inputPkgs`, `channels`,
  `username`) throw too -- they are options (or module arguments),
  and a specialArg of the same name would mask the real value -- as
  do the module-system-owned `pkgs`, `lib`, `config`, `options` and
  `modulesPath`. Set the corresponding builder argument instead.
  Default `{ }`.

- **group**
  Free-form host classification, e.g. `"vm"` or `"server"`.
  Exposed to modules as the read-only `nixpkgsLibExtensions.group`
  option; in a hosts attrset it also selects that host's `_groups`
  defaults layer (see `buildNixosConfigurations`). When non-null the
  host config convention looks under `hosts/<group>/` instead of
  `hosts/`, unless `hostFolder` overrides the segment. Default
  `null` (no classification, no grouping folder).

- **hostFolder**
  The folder segment of the host config convention, overriding the
  `group` default: the lookup happens under `hosts/<hostFolder>/`
  whatever `group` says. Decouples the folder layout from the
  classification. Default `null` (folder follows `group`).

- **rootPath**
  The root for the `hosts/<hostname>` convention and the `rootPath`
  specialArg. Default `inputs.self` (the consuming flake); throws
  when neither is available.

- **homeManager**
  Explicit home-manager input, bypassing the capability detection --
  use it when several inputs look like home-manager (the detection
  warns and picks the alphabetically first otherwise). Default `null`
  (detect).

- **inputContributions**
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
  `overlays`; `libOverlays` and `lib` hold a single value, so for them
  only `null`/`[ ]` (off) and `"*"` (on) apply. Naming entries is how you take
  SEVERAL of a catalog's exports -- and it is validated: an unknown
  channel key, an unknown entry name, or a case keyed by an input that is
  not in `inputs` all throw, listing the valid options. An explicit
  selection also overrides the built-in skips (the home-manager input,
  nixpkgs trees), which only exist to prevent guessing. UNAFFECTED BY
  ANY OF THIS: the `nixpkgsLibExtensions.channels` package-set variants
  (an unrelated use of "channel" from the export-kind sense above),
  `inputPkgs`, and the home-manager capability detection are all
  computed from `inputs` directly, so no `inputContributions` case
  touches them --
  `inputContributions."nixpkgs-unstable" = null;` still yields a
  `channels.unstable` entry. An input reached by hand via the `inputs`
  specialArg or the `inputPkgs` option likewise always works.
  Example: `inputContributions."nixos-raspberrypi".overlays =
  [ "bootloader" "vendor-kernel" ];`
  Default `{ }`.

`mkHomeConfiguration` accepts this same shared set, so both
builders can be called with one common argument attrset.




## `lib.nixos.normalUserModule`

A function from a username to a NixOS module declaring that user as a
normal account whose primary group is a private group named after the
user (the Debian/Fedora "user private group" scheme, instead of NixOS's
shared `users` group) -- so by default a user is only a member of their
own group.

This is the default `userModule` of `mkNixosSystem`, so
every user derived from the `userRegistry` gets a login
account automatically. Pass your own function when accounts need more,
or `userModule = null` to disable account creation.

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

# a custom userModule can build on it:
userModule = username: {
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


---

# strings


## `lib.strings.stringToTitle`

Capitalize the first character of a string, leaving the rest as it
was.

Deliberately NOT nixpkgs' `lib.toSentenceCase`, which upper-cases the
first character and LOWER-cases everything after it: this function
preserves the tail, so casing that carries meaning survives --
`stringToTitle "fooBar"` is `"FooBar"` where `toSentenceCase` gives
`"Foobar"`. For a string that is already all lowercase the two agree.

### Type
```
stringToTitle :: String -> String
```

### Arguments
- **text**
  The input string to capitalize

### Example
```nix
stringToTitle "hello world"
=> "Hello world"

stringToTitle "fooBar"
=> "FooBar"

stringToTitle ""
=> ""
```


---

# systemd


## `lib.systemd.detachedRun`

Run a shell command detached from the caller, in a fresh
`systemd-run --user` transient unit, following its journal for
interactive output and propagating its real exit status. Built for
commands whose own effects can restart the unit the CALLER is running
in -- `home-manager switch` is the motivating case (see
`interceptingWrapper`): its activation restarts every user unit whose
store path changed, which can include the very unit the calling
shell's cgroup lives in (a tmux-server.service, a timer unit's own
ExecStart, ...). Stopping that unit TERMs the in-flight activation --
stops run, starts never do. Running detached breaks that link: the
transient unit is never part of any restart set, so it completes even
if whatever launched it is killed mid-run; only the interactive
journal tail dies with it.

Returns a shell script FRAGMENT (a string), not a derivation -- splice
it into a wrapper script (`interceptingWrapper` does this) or straight
into a systemd unit's own `ExecStart` (a timer-triggered upgrade
service is exactly this: wrapping its own `home-manager switch` call
the same way protects it from the identical self-restart risk).
`command`, like `interceptingWrapper`'s `shouldDetach`, is raw shell
syntax spliced in verbatim (e.g. `"$real" "$@"`) -- not a Nix-modeled
argv list.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
# as a systemd service's ExecStart:
script = extLib.systemd.detachedRun pkgs {
  label = "hm-upgrade";
  command = "${pkgs.home-manager}/bin/home-manager switch";
  extraProperties = [ "RuntimeMaxSec=7200" ];
};
```

### Type

```
detachedRun :: pkgs -> Attribute -> String
```

### Arguments

- **pkgs**
  The package set `systemd-run`/`journalctl`/`systemctl` are taken from.

- **label**
  Names the transient unit (prefixed, followed by a timestamp and PID
  for uniqueness) AND the failure message verbatim -- keep it a valid
  systemd unit-name component (letters, digits, `:_.-`; no spaces). A
  human-readable label like "home-manager switch" reads better in the
  failure text but is not a legal unit name; a slug like "hm-switch"
  is both at once, at the cost of a plainer message.

- **command**
  Raw shell syntax for the command to run detached, e.g. `"$real" "$@"`
  or a fixed invocation. Spliced verbatim after `systemd-run`'s own
  flags.

- **extraEnv**
  Names of additional environment variables to forward into the
  transient unit, read from the CALLER's environment at runtime (a
  shell loop with indirect expansion, since their VALUES are not
  known until the script actually runs). `PATH` is always forwarded
  and does not need to be listed. Default `[ ]`.

- **extraProperties**
  Additional `systemd-run --property=` values, verbatim `"NAME=VALUE"`
  strings -- e.g. `[ "RuntimeMaxSec=7200" ]`. Unlike `extraEnv` these
  are static configuration, known at Nix eval time, so they are
  spliced directly rather than read from the runtime environment.
  Default `[ ]`.




## `lib.systemd.interceptingWrapper`

Shadow one binary from a package on `PATH`, routing matching
invocations through `detachedRun` and everything else straight to the
real binary. Built to fix commands like `home-manager switch` whose
OWN effects can kill the shell that invoked them (see `detachedRun`'s
doc comment for the mechanism and why); use this when that wrapping
needs to happen wherever the plain command name is typed, not just at
one fixed call site.

The wrapper's `bin/<binary>` wins name resolution via `lib.hiPrio`,
but everything else the real package ships (shell completions, other
binaries, ...) still comes from it: `symlinkJoin` merges the two,
priority only breaks the naming conflict on `binary` itself.

### Example

```nix
# extLib = inputs.nixpkgs-lib-extensions.lib
environment.systemPackages = [
  (extLib.systemd.interceptingWrapper pkgs {
    package = pkgs.home-manager;
    binary = "home-manager";
    # detach only `home-manager switch`; every other subcommand
    # (news, generations, ...) passes straight through
    shouldDetach = ''[ "${1:-}" = "switch" ]'';
    label = "hm-switch";
  })
];
```

### Type

```
interceptingWrapper :: pkgs -> Attribute -> Derivation
```

### Arguments

- **pkgs**
  The package set used to build the wrapper and passed through to
  `detachedRun`.

- **package**
  The real package to wrap, e.g. `pkgs.home-manager`.

- **binary**
  Which binary inside `package` to shadow (`${package}/bin/${binary}`)
  -- also the wrapper's own `writeShellScriptBin` name, so it is what
  actually wins on `PATH`.

- **shouldDetach**
  Raw shell syntax for the condition to detach on, checked against the
  wrapper's own positional parameters (`$1`, `$@`, ...) -- e.g.
  `''[ "${1:-}" = "switch" ]''`. True routes through `detachedRun`;
  false `exec`s the real binary with the same arguments. Not a
  Nix-modeled argv list: Nix cannot see the caller's real arguments,
  only shell can, at the moment the wrapper actually runs.

- **label**
  Passed straight through to `detachedRun` -- see its own doc comment.
  Default: `binary` (already a valid unit-name component).

- **extraEnv**
  Passed straight through to `detachedRun`. Default `[ ]`.

- **extraProperties**
  Passed straight through to `detachedRun`. Default `[ ]`.
