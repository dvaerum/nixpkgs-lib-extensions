# Changelog

The library's release is exported as `lib.version`. Renamed or removed
names become throwing tombstones that name their replacement and stay
for at least one release cycle -- see the versioning and deprecation
policy in the [README](README.md).

## 1.0.0

The first versioned release. Everything below landed together; the
breaking changes are all renames with tombstones, so a stale name fails
loudly with a pointer, never silently.

### Breaking: the singular builders are renamed

- `nixosConfigurationsBuilder` -> `mkNixosSystem`
- `homeConfigurationsBuilder` -> `mkHomeConfiguration`

Same arguments, same behavior; the old names read like the plural
`build*` family while each builds ONE system/home. The plural family
(`buildConfigurations`, `buildNixosConfigurations`,
`buildHomeConfigurations`) is unchanged. The old names are tombstones:
accessing one throws with the replacement.

Migration: `s/nixosConfigurationsBuilder/mkNixosSystem/` and
`s/homeConfigurationsBuilder/mkHomeConfiguration/` at the call sites.
A flake using only the plural family changes nothing.

### Breaking: the `extraOverlays` argument is renamed to `overlays`

Same behavior (applied on top of the overlays auto-collected from
`inputs`); the `extra` prefix now belongs to the per-host `extra.*`
layering slot and the old name read as if it were part of it. The old
name throws in every position (direct calls, `_defaults`, host entries,
`extra`) naming the new one.

Migration: `s/extraOverlays/overlays/` in builder arguments. A host
layering overlays writes `extra.overlays = [ ... ];` now.

### Breaking: `hostGroup` is split into `group` and `hostFolder`

`hostGroup` did two jobs: classify the host (the module-visible value)
and select the `hosts/<hostGroup>/` config folder. It is now:

- `group` -- the classification. Exposed to modules as the read-only
  `nixpkgsLibExtensions.group` option (the option's old `hostGroup`
  path is a tombstone), and BY DEFAULT still selects the
  `hosts/<group>/` folder, so for existing setups `group` is a pure
  rename.
- `hostFolder` -- optional; overrides the folder segment without
  touching the classification. `hostFolder = "vm"` looks under
  `hosts/vm/` whatever `group` says; `group` alone keeps the old
  folder-follows-group behavior.

The `hostGroup` builder argument throws naming `group`; the removed
`hostGroup` specialArg (tombstoned in an earlier release) now points at
`config.nixpkgsLibExtensions.group`.

Migration: `s/hostGroup/group/` in builder arguments, and
`s/nixpkgsLibExtensions.hostGroup/nixpkgsLibExtensions.group/` in
modules reading the option. Folder layouts need no change.

### New: `_groups.<name>` -- a defaults layer between `_defaults` and the host

The hosts attrset takes a second reserved key. Each `_groups.<name>`
entry is an argument set (same allowlist as `_defaults`, plus an
`extra` slot layering onto `_defaults`), and a host with
`group = "<name>";` receives it merged BETWEEN `_defaults` and its own
entry -- `_defaults`, then the group layer, then the host, later layers
winning per argument:

```nix
extLib.buildConfigurations {
  _defaults = { inherit inputs system; };
  _groups.server = {
    tags = [ "headless" ];
    extra.modules = [ ./common/server.nix ]; # adds to _defaults.modules
  };
  web1 = { group = "server"; };
  web2 = { group = "server"; };
  laptop = { };
}
```

When `_groups` is present, a host's `group` must name one of its
entries (unknown names throw); without `_groups`, `group` stays the
free-form classification it always was.

### Changed: `home.stateVersion` warns when a home relies on the default

Both home mechanisms still default `home.stateVersion` to the current
nixpkgs release, but a home that actually USES the default now gets a
warning (an eval warning plus a `warnings` entry) naming the user and
the two ways to pin: in that user's `home.nix`
(`home.stateVersion = "26.11";`) or fleet-wide via a shared
`homeModules` entry. Homes that pin are untouched -- neither the
warning nor the default value is ever evaluated for them.

### Changed: absolute path-STRING registry entries warn

A `userRegistry` value like `"/home/me/users/alice"` (a string, not a
path) still works but warns: string paths escape the flake -- they are
not copied to the store and break under pure evaluation. Write a path
value (`./users/alice`) instead.

### New: versioning

`lib.version` (this release: `"1.0.0"`), this changelog, and the
written deprecation policy in the README. The flat function names
(`extLib.buildConfigurations`) are declared the canonical surface over
the namespaced duplicates (`extLib.nixos.buildConfigurations`).

### Migration notes for a hosts-attrset fleet (e.g. healthcare-router)

For a consumer driving its fleet through `buildConfigurations` (or the
other plural builders) with `hostGroup` on its hosts -- the
healthcare-router shape, ~25 hosts:

1. **Mandatory:** rename `hostGroup` to `group` everywhere it appears
   in the hosts attrset (`_defaults` and host entries). This is the
   only required edit; folder layouts under `hosts/<group>/` keep
   working unchanged.
2. `s/extraOverlays/overlays/` if the argument is used.
3. Modules reading `config.nixpkgsLibExtensions.hostGroup` read
   `config.nixpkgsLibExtensions.group` instead.
4. The removed builder names (`nixosConfigurationsBuilder`,
   `homeConfigurationsBuilder`) only matter where they were called
   DIRECTLY; the plural family is untouched.
5. Homes that do not pin `home.stateVersion` start warning; pin per
   user or once via shared `homeModules`.

Then `nix flake update nixpkgs-lib-extensions` and a
`nixos-rebuild build` on one host verifies the result; any stale name
fails with an error naming its replacement.
