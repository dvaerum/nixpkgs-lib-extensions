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
attrList
: List of attribute sets to merge

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

Generate a zfs filesystem for a user

### Example

```nix
DeclareZfsRootDisk {
  inherit pkgs lib;
  devicePath = "/dev/disk/by-id/nvme-WDC_PC_SN479_WEFWOER-512G-1233_23425X589324";
  listOfUsernames = [ "foo" { name: "bar"; } { name: "bar"; home: "/home/bar2"; } ]
  hostname = config.networking.hostname;
  enableEncryption = false;
}
=>
{ ... }
```

### Type

```
DeclareZfsRootDisk :: Attribute -> Attribute
```

### Arguments

pkgs
: `pkgs` from nixpkgs or the nixpkgs 😅 Need for the `dmidecode` package

lib
: `lib` from nixpkgs.

devicePath
: The absolute path to the device

hostname
: The name of the device. The pool will be name: zroot-<HOSTNAME>

enableEncryption
: Enable or Disable of the drive should be encrypted.
: Currently the encryption is using the motherboards UUID.
: You can find it with the command: `dmidecode --string system-uuid`

swapSize
: Set the size (in GiB) of the SWAP partition. Default is `32`.
: Set it to `0` to disable having a SWAP partition.

useZfsForTmp
: Select if `/tmp` should be a zfs dataset with
: `sync=disabled`, `setuid=off` and `devices=off` or
: if it should be `tmpfs`.

listOfUsernames
: A list of `string` or `attribute` element (may be mixed).
: The `string` element is: <USERNAME>.
: The `attribute` element is: { name = "<USERNAME>"; mountpoint = "<MOUNTPOINT>"; }

defineBootPartitions
: Defines boot partitions for systems that are not `x86_64-linux` or `aarch64-linux`,
: or when boot partitions must be overwritten


# strings {#sec-functions-library-strings}


## `lib.strings.stringToTitle` {#lib.strings.stringToTitle}

Capitalize the first character of a string.

### Type
stringToTitle :: String -> String

### Arguments
text
: The input string to capitalize

### Example
```nix
stringToTitle "hello world"
=> "Hello world"

stringToTitle "foobar"
=> "Foobar"

stringToTitle ""
=> ""
```


