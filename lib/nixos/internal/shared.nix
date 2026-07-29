# Shared helpers for the builders in lib/nixos (nixosConfigurationsBuilder,
# homeConfigurationsBuilder and homeManagerBootstrapModule).
#
# This file lives in a subfolder so the lib loader (lib/default.nix) does not
# pick it up as part of the public lib; the builder files import it directly:
#
#   extLib: let shared = import ./internal/shared.nix extLib; in { ... }
#
# Like the builder files it is a function of `extLib` — the fully assembled
# nixpkgs-lib-extensions lib.
extLib:
let
  # The home-manager input, detected by capability (its `lib` exposes
  # `homeManagerConfiguration`) rather than by name, so it is found no matter
  # what the consuming flake calls the input. null if none is present.
  detectHomeManager =
    inputs:
    let
      candidates = builtins.filter (
        v: builtins.isAttrs v && (v.lib or { }) ? homeManagerConfiguration
      ) (builtins.attrValues inputs);
    in
    if candidates == [ ] then null else builtins.head candidates;

  # Registry values must be directories: a path literal or an absolute string
  # pointing at an existing directory.
  isDirEntry =
    entry:
    (builtins.isPath entry || (builtins.isString entry && builtins.substring 0 1 entry == "/"))
    && builtins.pathExists entry
    && builtins.readFileType entry == "directory";

  # `builtins.warn` needs Nix >= 2.23; fall back to a trace with the same look.
  warn = builtins.warn or (msg: val: builtins.trace "evaluation warning: ${msg}" val);

  # The registry entries that apply for `username` on `hostname`:
  # "<user>@<host>" and "<user>@*" both apply (and merge); the plain "<user>"
  # entry is a standalone default, used ONLY when no @-entry matched -- it is
  # never merged with @-entries (import it explicitly from another entry to
  # reuse it). A plain entry shadowed by @-entries triggers a warning.
  matchedEntries =
    userRegistry: hostname: username:
    let
      atTier = builtins.filter (e: e != null) [
        (userRegistry."${username}@*" or null)
        (userRegistry."${username}@${hostname}" or null)
      ];
      fallback = userRegistry.${username} or null;
    in
    if atTier != [ ] then
      (if fallback != null then
        warn ''
          userRegistry: the plain `${username}` entry is IGNORED on host
          `${hostname}` because `${username}@...` entries exist. Plain entries
          are standalone defaults, never merged with @-entries; import the
          directory explicitly from an @-entry if you want to reuse it.
        '' atTier
      else
        atTier)
    else if fallback != null then
      [ fallback ]
    else
      [ ];

  # Validate one registry entry and return its parts. Every entry must be a
  # directory shipping `home.nix` (home-manager config) and/or
  # `configuration.nix` (NixOS config for that user: account, groups, ...).
  entryFiles =
    username: entry:
    let
      shown =
        if builtins.isPath entry || builtins.isString entry then
          toString entry
        else
          "a value of type `${builtins.typeOf entry}`";
      hasHome = builtins.pathExists (entry + "/home.nix");
      hasConf = builtins.pathExists (entry + "/configuration.nix");
    in
    if !(isDirEntry entry) then
      throw ''
        The userRegistry entry for `${username}` must be an existing
        directory (as a path), but got: ${shown}
      ''
    else if !hasHome && !hasConf then
      throw ''
        The userRegistry directory for `${username}` (${shown})
        contains neither a `home.nix` nor a `configuration.nix`.
      ''
    else
      {
        homeModule = if hasHome then entry + "/home.nix" else null;
        nixosModule = if hasConf then entry + "/configuration.nix" else null;
      };

  # Everything that applies for a user on a host, across the matched entries:
  # `homeModules` for home-manager, `nixosModules` for the system. A user
  # whose matched entries only ship configuration.nix is system-only
  # (homeModules == [ ]): no home output, no login bootstrap.
  resolveUser =
    userRegistry: hostname: username:
    let
      parts = map (entryFiles username) (matchedEntries userRegistry hostname username);
      nonNull = builtins.filter (x: x != null);
    in
    {
      homeModules = nonNull (map (p: p.homeModule) parts);
      nixosModules = nonNull (map (p: p.nixosModule) parts);
    };

  # The subset of `users` that actually have a home configuration.
  usersWithHome =
    userRegistry: hostname: users:
    builtins.filter (u: (resolveUser userRegistry hostname u).homeModules != [ ]) users;

  # The users of a host, derived from the registry keys: "<user>@<host>" entries
  # for this host, "<user>@*" wildcard entries (every host), plus plain
  # "<user>" fallback entries (any host). Deduplicated (and sorted) via the
  # listToAttrs/attrNames round-trip.
  usersFromRegistry =
    userRegistry: hostname:
    let
      toUser =
        key:
        let
          m = builtins.match "(.*)@(.*)" key;
          host = builtins.elemAt m 1;
        in
        if m == null then
          key
        else if host == hostname || host == "*" then
          builtins.head m
        else
          null;
      names = builtins.filter (u: u != null) (map toUser (builtins.attrNames userRegistry));
    in
    builtins.attrNames (
      builtins.listToAttrs (
        map (u: {
          name = u;
          value = null;
        }) names
      )
    );

  # From a flake's exported set (modules / overlays): the `default` export
  # is auto-loaded; without one, a set with exactly ONE entry is unambiguous
  # (sops-nix / plasma-manager style) and that entry is used. A set with
  # SEVERAL entries and no `default` is a catalog of opt-in entries
  # (nixos-hardware ships hundreds of mutually exclusive profiles, some of
  # them `throw` tombstones) -- importing them all is never right, so it
  # contributes nothing. Reference catalog entries explicitly (e.g.
  # `inputs.nixos-hardware.nixosModules.<profile>`) or add an
  # `inputSpecialCases` entry mapping the input onto the convention.
  pickExported =
    s:
    if s ? default then
      [ s.default ]
    else if builtins.length (builtins.attrNames s) == 1 then
      builtins.attrValues s
    else
      [ ];

  # Special cases for inputs that do not follow the generic output
  # conventions, keyed by the input's NAME in `inputs`. A case applies ONLY
  # to the input with that exact key and never affects the generic handling
  # of anything else. Each case maps the input onto the standard convention
  # attributes (nixosModules / homeManagerModules / homeModules / overlays /
  # extendLib); the generic collectors then treat it like any other input.
  # Add further special cases here.
  inputSpecialCases = {
    # NUR exports its modules under `modules.nixos` / `modules.homeManager`
    nur = v: {
      nixosModules = v.modules.nixos or { };
      homeManagerModules = v.modules.homeManager or { };
    };
  };

  # The convention-shaped view of an input: its special case applied when
  # one exists for its name, the input itself otherwise.
  normalizeInput =
    name: v:
    if builtins.isAttrs v && inputSpecialCases ? ${name} then v // inputSpecialCases.${name} v else v;

  # Shared context: everything the builders need (lib, pkgs, specialArgs and the
  # auto-collected module/overlay sets). Builder-specific arguments are ignored
  # here via `...`.
  mkContext =
    {
      inputs,
      hostname,
      system,
      nixpkgs ? inputs.nixpkgs,
      tags ? [ ],
      patches ? [ ],
      extraOverlays ? [ ],
      allowedUnfreePackages ? [ ],
      permittedInsecurePackages ? [ ],
      specialArgs ? { },
      additionalSpecialArgs ? { },
      nixpkgsConfig ? { },
      systemType ? null,
      rootPath ? (inputs.self or ./.),
      excludeModuleInputs ? [ ],
      ...
    }:
    let
      baseLib = nixpkgs.lib;

      # Extend the system lib with this repo's own extensions (`extLib`, always
      # available since the builders are part of nixpkgs-lib-extensions) plus any
      # other input that exposes an `extendLib` function.
      libExtenders = baseLib.filter (v: baseLib.isAttrs v && v ? extendLib) (baseLib.attrValues inputs);
      extendedLib = baseLib.foldl' (acc: ext: acc.extend (final: prev: ext.extendLib prev)) (
        baseLib.extend (final: prev: baseLib.recursiveUpdate prev extLib)
      ) libExtenders;

      # Each input's standalone `lib` export, namespaced by input name:
      # exposed as `lib.<name>` in modules and as `pkgs.lib.<name>` (e.g.
      # `lib.NixVirt.domain`). A plain `lib` export is a foreign namespace
      # and is never merged flat -- `extendLib` remains the composable way
      # into the flat lib. Skipped: nixpkgs trees (their lib IS the base).
      libsFromInputs =
        let
          raw = baseLib.mapAttrs (_: v: v.lib) (
            baseLib.filterAttrs (
              name: v:
              baseLib.isAttrs v
              && baseLib.isAttrs (v.lib or null)
              && !(v ? legacyPackages && v.lib ? nixosSystem)
            ) inputs
          );
        in
        # The consuming flake's own lib output (inputs.self) is renamed to
        # `flake`: `lib.flake.<helper>` reads as "from this flake", where
        # `lib.self` would read oddly. An explicit input actually named
        # `flake` keeps the name; self's lib is then dropped with a warning.
        if raw ? self && !(raw ? flake) then
          builtins.removeAttrs raw [ "self" ] // { flake = raw.self; }
        else if raw ? self then
          warn "nixpkgs-lib-extensions: not exposing the consuming flake's `lib` as `lib.flake`: an input named `flake` already claims the name." (
            builtins.removeAttrs raw [ "self" ]
          )
        else
          raw;

      # Namespaces this repo OWNS: extLib's folder namespaces that nixpkgs'
      # lib does not also define (e.g. `disko`, `nixos`, `imports` -- but
      # not `strings` or `attrsets`, which exist in nixpkgs too). These are
      # the only legitimate merge targets for an input's lib export.
      ownedNamespaces = builtins.filter (n: baseLib.isAttrs extLib.${n} && !(baseLib ? ${n})) (
        builtins.attrNames extLib
      );

      # Overwrite detection, per collision class:
      # - name unused              -> input lib added as `lib.<name>`
      # - name is an OWNED namespace -> recursive merge, the existing side
      #   wins every conflict: an input can only ADD, never change (so a
      #   `disko` input's helpers join declareZfsRootDisk under lib.disko)
      # - any other existing name (nixpkgs's `strings`, ...) -> skipped
      #   with a warning; such an input name is almost always an accident
      # Computed ONCE per context and shared by the module lib, pkgs.lib
      # and every pkgs-* variant, so a warning fires once per host, not
      # once per lib construction.
      inputLibAdditions =
        let
          existing = builtins.intersectAttrs extendedLib libsFromInputs;
          owned = builtins.intersectAttrs (baseLib.genAttrs ownedNamespaces (_: null)) existing;
          skipped = builtins.attrNames (
            builtins.removeAttrs existing (builtins.attrNames owned)
          );
        in
        (
          if skipped == [ ] then
            x: x
          else
            warn ''
              nixpkgs-lib-extensions: not namespacing the `lib` export of input(s) ${builtins.concatStringsSep ", " skipped}: the name collides with a `lib` attribute this repo does not own. Rename the input to expose its lib as `lib.<name>`.''
        )
          (
            builtins.removeAttrs libsFromInputs (builtins.attrNames existing)
            // builtins.mapAttrs (n: inputLib: baseLib.recursiveUpdate inputLib extendedLib.${n}) owned
          );

      # Through the fixed point (`extend`), NOT a plain `//`: evalModules
      # hands modules the lib from its own fixed point, so additions merged
      # outside it would be invisible as the module-arg `lib`.
      lib = extendedLib.extend (final: prev: inputLibAdditions);

      # allowedUnfreePackages / permittedInsecurePackages are the ergonomic
      # shorthands; nixpkgsConfig is the general escape hatch into
      # `nixpkgs.config` (cudaSupport = true; ...) and is merged last, so
      # it can also override what the shorthands produced.
      pkgsConfig = {
        allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) allowedUnfreePackages;
        inherit permittedInsecurePackages;
      }
      // nixpkgsConfig;

      # Optionally apply patches to a nixpkgs source tree.
      patchSrc =
        npkgs:
        if patches == [ ] then
          npkgs
        else
          npkgs.legacyPackages.${system}.applyPatches {
            name = "nixpkgs-patched-src";
            src = npkgs;
            inherit patches;
          };

      # The collectors see inputs through their special case (if any); the
      # `inputs`/`inputPkgs` specialArgs stay raw.
      conventionInputs = builtins.mapAttrs normalizeInput inputs;

      # Auto-collect overlays (package extensions) from every input exposing `overlays`.
      autoOverlays = lib.unique (
        lib.concatLists (
          lib.mapAttrsToList (name: v: lib.optionals (lib.isAttrs v && v ? overlays) (pickExported v.overlays)) conventionInputs
        )
      );

      mkPkgs =
        npkgs:
        import (patchSrc npkgs) {
          inherit system;
          # the input-lib namespacing overlay sits between the collected
          # input overlays and the caller's extraOverlays, so extraOverlays
          # can still override pkgs.lib entirely
          overlays =
            autoOverlays ++ [ (final: prev: { lib = prev.lib // inputLibAdditions; }) ] ++ extraOverlays;
          config = pkgsConfig;
        };

      selectedSrc = patchSrc nixpkgs;
      pkgs = mkPkgs nixpkgs;

      home-manager = detectHomeManager inputs;

      # Identity (store path) of the home-manager input, so its NixOS module is
      # kept out of the auto-collected set no matter how the input is named.
      homeManagerId = if home-manager == null then null else home-manager.outPath or null;

      # Skip when auto-collecting NixOS modules:
      # - the home-manager input (used standalone; matched by identity, not name)
      # - nixpkgs trees, identified by `legacyPackages` PLUS `lib.nixosSystem`:
      #   they export helper modules like `readOnlyPkgs` that would break the
      #   system when imported blindly. `legacyPackages` alone is not enough
      #   to skip -- flakes like sops-nix export it (docs/packages) while also
      #   shipping a real `nixosModules.default` that must be imported.
      # - anything listed in `excludeModuleInputs`
      skipNixosModule =
        name: v:
        (homeManagerId != null && (v.outPath or null) == homeManagerId)
        || (v ? legacyPackages && (v.lib or { }) ? nixosSystem)
        || lib.elem name excludeModuleInputs;

      # Auto-collect NixOS modules from every input exposing `nixosModules`.
      autoNixosModules = lib.unique (
        lib.concatLists (
          lib.mapAttrsToList (
            name: v:
            lib.optionals (lib.isAttrs v && v ? nixosModules && !(skipNixosModule name v)) (pickExported v.nixosModules)
          ) conventionInputs
        )
      );

      # Auto-collect home-manager modules from inputs exposing them under the
      # `homeModules` convention, falling back to the older
      # `homeManagerModules` name only when `homeModules` is absent --
      # flakes like plasma-manager keep `homeManagerModules` as a
      # deprecation alias that WARNS on access, so it must not be touched
      # when the new name exists.
      autoHomeModules = lib.unique (
        lib.concatLists (
          lib.mapAttrsToList (
            name: v:
            lib.optionals (lib.isAttrs v) (pickExported (v.homeModules or v.homeManagerModules or { }))
          ) conventionInputs
        )
      );

      # Expose every other `nixpkgs-*` input as a `pkgs-*` specialArg, built the
      # same way as the primary (e.g. nixpkgs-unstable -> pkgs-unstable).
      pkgsFromInputs = lib.mapAttrs' (
        name: np: lib.nameValuePair "pkgs-${lib.removePrefix "nixpkgs-" name}" (mkPkgs np)
      ) (lib.filterAttrs (name: v: lib.hasPrefix "nixpkgs-" name && lib.isAttrs v && v ? legacyPackages) inputs);

      # Every input's packages, pre-selected for this system: e.g.
      # `inputPkgs.disko.disko-install`. Deliberately NOT merged into `pkgs`
      # (input names would silently shadow nixpkgs attributes); an input's own
      # `overlays.default` -- which IS auto-applied -- is the flake author's
      # sanctioned way into `pkgs`.
      inputPkgs = lib.mapAttrs (_: v: v.packages.${system}) (
        lib.filterAttrs (_: v: lib.isAttrs v && (v.packages or { }) ? ${system}) inputs
      );

      # The whole `inputs` set is exposed so modules can reach anything not
      # covered by the generic conventions (e.g. inputs.fenix) themselves --
      # the lib carries no per-input special cases.
      # Note: `pkgs` deliberately not included — modules already receive it from
      # the module system, and `specialArgs.pkgs` would override that wiring
      # (nixpkgs warns about it).
      mySpecialArguments =
        {
          inherit
            hostname
            inputs
            inputPkgs
            rootPath
            tags
            extLib
            systemType
            ;
        }
        // pkgsFromInputs
        // specialArgs
        # the per-host extension slot: layered after specialArgs so that
        # `_defaults.specialArgs` and a host's additionalSpecialArgs combine
        # (mirroring modules/additionalModules)
        // additionalSpecialArgs;
    in
    {
      inherit
        lib
        pkgs
        selectedSrc
        mySpecialArguments
        home-manager
        autoNixosModules
        autoHomeModules
        ;
    };
  # ONE hosts attrset is meant to feed BOTH buildNixosConfigurations and
  # buildHomeConfigurations, so both validate against the same allowlists:
  # arguments only one side uses (modules, userModuleFn, homeSharedModules,
  # ...) are accepted everywhere and ignored by the other side.
  # Keep in sync with the documented argument lists.
  allowedDefaultArgs = [
    "inputs"
    "system"
    "nixpkgs"
    "rootPath"
    "modules"
    "userModuleFn"
    "excludeModuleInputs"
    "userRegistry"
    "loginUsers"
    "homeSharedModules"
    "loginFlakeRef"
    "loginReactivateEveryLogin"
    "tags"
    "systemType"
    "patches"
    "extraOverlays"
    "allowedUnfreePackages"
    "permittedInsecurePackages"
    "nixpkgsConfig"
    "specialArgs"
  ];
  allowedHostArgs = allowedDefaultArgs ++ [
    "hostname"
    "additionalModules"
    "additionalSpecialArgs"
  ];

  # Validate a hosts attrset (the shared input of both build* functions)
  # and split it into { defaults, hostEntries }. Throws, naming fnName,
  # on: a non-allowlisted `_defaults` key (with special explanations for
  # `hostname` and the `additional*` per-host halves), a non-allowlisted
  # host entry key, or a host entry whose inner `hostname` conflicts
  # with its attribute key (a redundant EQUAL one is tolerated).
  splitHostsArgs =
    fnName: hosts:
    let
      defaults = hosts._defaults or { };
      defaultComplaint =
        name:
        if name == "hostname" then
          "- `hostname`: never a default -- it comes from each attribute key. Drop it."
        else if builtins.substring 0 10 name == "additional" then
          "- `${name}`: the `additional*` arguments are the per-host halves of the layered pairs (modules/additionalModules, specialArgs/additionalSpecialArgs). Set the base half in `_defaults`, the additional half on the host entry."
        else
          "- `${name}`: not a builder argument (typo?). `_defaults` accepts: ${builtins.concatStringsSep ", " allowedDefaultArgs}.";
      badDefaults = map defaultComplaint (
        builtins.filter (k: !(builtins.elem k allowedDefaultArgs)) (builtins.attrNames defaults)
      );
      hostEntries = builtins.removeAttrs hosts [ "_defaults" ];
      badHostKeys = builtins.concatLists (
        builtins.attrValues (
          builtins.mapAttrs (
            hostname: args:
            map (
              k:
              "- `${hostname}`: `${k}` is not a builder argument (typo?). Host entries accept: ${builtins.concatStringsSep ", " allowedHostArgs}."
            ) (builtins.filter (k: !(builtins.elem k allowedHostArgs)) (builtins.attrNames args))
            ++ (
              if args ? hostname && args.hostname != hostname then
                [
                  "- `${hostname}`: also sets `hostname = \"${args.hostname}\"`. The attribute key is the hostname; drop the inner one."
                ]
              else
                [ ]
            )
          ) hostEntries
        )
      );
      problems = badDefaults ++ badHostKeys;
    in
    if problems != [ ] then
      throw ''
        ${fnName}: invalid hosts attrset:
        ${builtins.concatStringsSep "\n" problems}
      ''
    else
      { inherit defaults hostEntries; };
in
{
  inherit
    detectHomeManager
    resolveUser
    usersFromRegistry
    usersWithHome
    pickExported
    mkContext
    allowedDefaultArgs
    allowedHostArgs
    splitHostsArgs
    ;
}
