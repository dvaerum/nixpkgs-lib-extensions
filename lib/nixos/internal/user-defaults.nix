# Per-user builder-argument overrides read from `users/<u>/_defaults.nix`
# and `users/<u>/hosts/<h>/_defaults.nix`. One of the concern-files
# aggregated by ./shared.nix (which documents the shared `{ lib, self, ... }`
# calling convention).
#
# Exists for one job the users tree could not do before: a host-less home
# (`homeConfigurations."<user>"`, no `hosts/<h>` directory) still needs a
# `system` to build against, and nothing about `home.nix` can say what it
# is -- `home.nix` is a MODULE, applied inside a fixed point that already
# has a `pkgs`. This file is read and merged BEFORE that fixed point
# exists, by the caller in hosts-args.nix, which is also where the merge
# happens (this file has no dependency on hosts-args.nix, to avoid a
# import cycle -- it only reads, validates shape, and validates the
# allowlist).
#
# `isSystemUser`/`isNormalUser` (below) are a SEPARATE consumer of this
# same file, read directly by mk-system.nix rather than through
# hosts-args.nix's `userOverridesFor` (see there): unlike the home-shaping
# arguments above, this pair decides the user's NixOS ACCOUNT kind, which
# `normalUserModule` used to infer by reading the merged
# `config.users.users.<name>.uid` -- a cross-namespace read from inside
# account-creation modules that once caused a genuine infinite recursion
# on a real host (see normal-user-module.nix's own doc comment). Declaring
# it here instead keeps the decision entirely at builder time, before any
# module evaluation starts, the same way the rest of the users tree scan
# already does -- so it can never reintroduce that cycle.
{ lib, self, ... }:
let
  # What a user's `_defaults.nix` may set: home-shaping arguments (see the
  # file header above for why `system` is here), plus the account-kind
  # pair `isSystemUser`/`isNormalUser`. `system` (bare) is exactly what
  # this file exists to let a user set -- see build-home-configurations.nix's
  # own doc comment for why. Deliberately excludes: `rootPath`/
  # `loginFlakeRef`/`inputs` (circular -- they LOCATE this very file);
  # `users`/`loginHomes`/`group`/`hostFolder`/`userModule`/`modules`/
  # `systemAutoUpgrade`/`systemAutoUpgradeFlakeRef`/`systemGarbageCollect`/
  # `wrapHomeManagerSwitch`/`loginReactivateEveryLogin`/
  # `traceDiscoveredUsers` (host concerns, not a user's to set); and
  # `patches`/`nixpkgs`/`homeManager`/`inputContributions` (fleet
  # decisions -- `patches` is also IFD-heavy, which this file's own read
  # cannot absorb, see readUserDefaultsRaw below).
  allowedUserDefaultsArgs = [
    "system"
    "homeModules"
    "specialArgs"
    "tags"
    "homeAutoUpgrade"
    "homeAutoUpgradeFlakeRef"
    "overlays"
    "nixpkgsConfig"
    "allowedUnfreePackages"
    "permittedInsecurePackages"
    "isSystemUser"
    "isNormalUser"
  ];

  # The `hosts/<h>/_defaults.nix` form additionally accepts `extra`, the
  # same per-file layering slot the hosts attrset's own `_defaults` ->
  # host-entry merge uses (hosts-args.nix): a bare key here REPLACES the
  # base file's value, `extra.<key>` ADDS to it. The base file itself
  # rejects `extra` -- nothing precedes it to add to, same reasoning as
  # `_defaults` rejecting `extra` there.
  allowedUserHostDefaultsArgs = allowedUserDefaultsArgs ++ [ "extra" ];

  # `dir` is a user's own directory (base, or a `hosts/<h>` override);
  # `null` when nothing applies there (host-less lookups pass `dir`
  # unconditionally, so this must tolerate `null`). ONE `pathExists`
  # probe, same shape as registry.nix's own `entryFiles` checks -- never
  # `readDir`s the directory, so a stray unrelated file next to
  # `_defaults.nix` is not this function's concern.
  userDefaultsPath =
    dir:
    if dir != null && lib.pathExists (dir + "/_defaults.nix") then dir + "/_defaults.nix" else null;

  # BARE `import`, not `importIfNixOr`: that needs a `pkgs` to run its IFD
  # probe, and a `pkgs` needs a core -- which is exactly what this file
  # may decide the shape of (it can set `system`). So unlike `home.nix`/
  # `configuration.nix`, a malformed or still-encrypted `_defaults.nix`
  # ABORTS evaluation rather than degrading to a default. Document this
  # loudly wherever the file is introduced to a reader.
  #
  # Dispatch on `builtins.isFunction`, never `lib.isFunction` -- that also
  # accepts `__functor` attrsets, which must fall through to the
  # plain-attrset branch untouched (see inputs.nix's own note on the same
  # trap, `internal/inputs.nix`).
  readUserDefaultsRaw =
    path: context:
    let
      value = import path;
    in
    if builtins.isFunction value then value context else value;

  # Exposed as DATA, not just a throw: a bare `import`'s error message is
  # not observable in-language (unlike a throw's own text, `tryEval`
  # discards it), so tests pin this by calling it directly rather than by
  # catching the real throw -- same reason `stringFlakeRefWarning` and
  # `probeCoreOverrideMessage` are functions rather than inline strings.
  userDefaultsShapeMessage =
    path: raw:
    "${toString path}: must evaluate to an attribute set (or a function returning one), but evaluated to a ${builtins.typeOf raw}.";

  checkedShape =
    path: raw: if lib.isAttrs raw then raw else throw (userDefaultsShapeMessage path raw);

  # Problems-as-data + (the caller's own) throwing wrapper, same pairing
  # as builderArgProblems/validateBuilderArgs (hosts-args.nix) -- so tests
  # assert on the MESSAGE, not just "it threw". `allowed` is one of the
  # two lists above; `isHostLayer` only changes the `extra` rejection
  # wording for the base-file case.
  userDefaultsProblems =
    allowed: isHostLayer: path: overrides:
    let
      bad = lib.filter (k: !(lib.elem k allowed)) (lib.attrNames overrides);
    in
    map (
      k:
      if k == "extra" && !isHostLayer then
        "${toString path}: \`extra\` is the per-host layering slot, never a default -- the base _defaults.nix holds the values a hosts/<h>/_defaults.nix's \`extra\` adds to."
      else
        "${toString path}: \`${k}\` is not settable from a user's _defaults.nix (typo, or a host/fleet concern?). Accepted: ${lib.concatStringsSep ", " allowed}."
    ) bad;

  validateUserDefaults =
    allowed: isHostLayer: path: overrides:
    let
      problems = userDefaultsProblems allowed isHostLayer path overrides;
    in
    if problems == [ ] then overrides else throw (lib.concatStringsSep "\n" problems);

  # The full read for ONE directory: `dir` -> the validated override
  # attrset, `{ }` when no `_defaults.nix` exists there. `context` (see
  # hosts-args.nix's construction of it) is only ever forced if the file
  # exists and is a function.
  readUserDefaults =
    allowed: isHostLayer: dir: context:
    let
      path = userDefaultsPath dir;
    in
    if path == null then
      { }
    else
      validateUserDefaults allowed isHostLayer path (
        checkedShape path (readUserDefaultsRaw path context)
      );

  # Resolves the account-kind pair from a user's (already validated)
  # `_defaults.nix` overrides. Both explicit and contradictory is a
  # BUILD-TIME throw -- clearer than NixOS's own runtime "exactly one of
  # `isSystemUser` and `isNormalUser` must be set" assertion, and
  # catchable before any module evaluation starts at all. Declaring only
  # one implies the other; declaring neither (the common case) defaults
  # to a normal account, matching `normalUserModule`'s own historical
  # default for a user with no uid pinned.
  accountKindMessage =
    path:
    "${toString path}: sets both \`isSystemUser = true\` and \`isNormalUser = true\` -- exactly one may be true (or neither, which defaults to a normal account).";

  resolveAccountKind =
    path: overrides:
    let
      declaredSystem = overrides.isSystemUser or false;
      declaredNormal = overrides.isNormalUser or false;
    in
    if declaredSystem && declaredNormal then
      throw (accountKindMessage path)
    else if declaredSystem then
      {
        isSystemUser = true;
        isNormalUser = false;
      }
    else
      {
        isSystemUser = false;
        isNormalUser = true;
      };

  # The full per-user account-kind read: the BASE `_defaults.nix` only --
  # deliberately not the `hosts/<h>` override layer `userOverridesFor`
  # (hosts-args.nix) applies for home-shaping arguments. An account's
  # fundamental kind is the same on every host it appears on, so this
  # does not replicate that file's full host-override-layering machinery
  # (which also cannot be imported here without a cycle -- see the file
  # header above). `context` is only forced if the file exists and is a
  # function (readUserDefaultsRaw).
  accountKindFor =
    dir: context:
    resolveAccountKind (userDefaultsPath dir) (
      readUserDefaults allowedUserDefaultsArgs false dir context
    );
in
{
  inherit
    allowedUserDefaultsArgs
    allowedUserHostDefaultsArgs
    userDefaultsPath
    readUserDefaultsRaw
    userDefaultsShapeMessage
    userDefaultsProblems
    validateUserDefaults
    readUserDefaults
    accountKindMessage
    resolveAccountKind
    accountKindFor
    ;
}
