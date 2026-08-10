# The shared evaluation context of the lib/nixos builders: `mkContext`
# assembles everything a builder needs (lib, pkgs, specialArgs and the
# auto-collected module/overlay sets) from one argument attrset. One of
# the concern-files aggregated by ./shared.nix.
#
# The context is built in two layers:
#   mkContextCore  the host-INDEPENDENT part, a function of the core
#                  arguments only (coreArgNames below) -- this is where
#                  the expensive `import nixpkgs { ... }` happens
#   mkContext      the per-host layer on top (mySpecialArguments); its
#                  FIRST parameter is the core -- `null` to compute one,
#                  or one planHosts already built, which is how
#                  buildNixosConfigurations/buildHomeConfigurations share
#                  ONE core across all hosts agreeing on the core arguments
#
# Takes the loader's `{ lib, self, ... }`: nixpkgs' lib, and the fully
# assembled nixpkgs-lib-extensions lib.
{ lib, self, ... }:
let
  inherit (import ./module-level.nix { inherit lib self; }) addOwnLib;
  # the moved-specialArg names (values here: replacement paths, unused --
  # only the NAMES matter for reserving them below)
  movedSpecialArgs = (import ./ext-options.nix { inherit lib self; }).movedNixosSpecialArgs;
  inherit (import ./inputs.nix { inherit lib self; })
    detectHomeManager
    libOf
    channelEnabled
    collectFromInputs
    isNixpkgsTree
    ;

  # The argument names mkContextCore consumes -- everything the
  # host-independent part of the context depends on. The build* functions
  # use this list to group hosts into core-sharing equivalence classes:
  # hosts agreeing on ALL of these share one core.
  #
  # DERIVED, not transcribed. As a hand-written list it was a silent
  # correctness hazard: add a parameter to mkContextCore below, forget the
  # list, and every host overriding that parameter quietly shares a core
  # built WITHOUT it -- the argument looks applied and is not. `functionArgs`
  # reads the formals of the lambda without forcing its body, so this cannot
  # drift.
  coreArgNames = builtins.attrNames (builtins.functionArgs mkContextCore);

  # The DEFAULT VALUES of mkContextCore's optional core arguments, in one
  # place: the formals below read them from here, and planHosts reads the
  # same attrset to fill in what a host left unsaid before comparing hosts
  # for core sharing. It used to hand-transcribe these values, and a changed
  # default with a stale copy makes a host silently share the WRONG core.
  # Not here: `inputs`/`system` (required, no default) and `nixpkgs`, whose
  # default is COMPUTED from `inputs` rather than a constant.
  # checks/builders/tests/defaults.nix asserts this table and the formals
  # cannot drift apart.
  coreDefaults = {
    patches = [ ];
    extraOverlays = [ ];
    allowedUnfreePackages = [ ];
    permittedInsecurePackages = [ ];
    nixpkgsConfig = { };
    homeManager = null;
    inputContributions = { };
  };

  # The host-independent context core: lib, pkgs, the auto-collected
  # module/overlay sets and the derived package sets -- everything that
  # depends only on the core arguments (coreArgNames), NOT on
  # hostname/tags/rootPath/specialArgs/... . Builder-specific and
  # per-host arguments are ignored here via `...`.
  mkContextCore =
    {
      inputs,
      system,
      nixpkgs ? inputs.nixpkgs,
      patches ? coreDefaults.patches,
      extraOverlays ? coreDefaults.extraOverlays,
      allowedUnfreePackages ? coreDefaults.allowedUnfreePackages,
      permittedInsecurePackages ? coreDefaults.permittedInsecurePackages,
      nixpkgsConfig ? coreDefaults.nixpkgsConfig,
      homeManager ? coreDefaults.homeManager,
      inputContributions ? coreDefaults.inputContributions,
      ...
    }:
    let
      baseLib = nixpkgs.lib;

      # Everything about what the INPUTS contribute lives in ./inputs.nix:
      # the case classification, the per-channel selection, the eager
      # validation and the collectors themselves. context.nix keeps the two
      # things that are genuinely its own -- constructing `lib` and
      # constructing `pkgs` -- and asks for the rest.
      fromInputs = collectFromInputs {
        inherit inputs inputContributions baseLib;
        skipFor.nixosModules = skipNixosModule;
      };
      inherit (fromInputs)
        conventionInputs
        caseOf
        collected
        selectionsChecked
        ;

      # Extend the system lib with this repo's own extensions (`self`, always
      # available since the builders are part of nixpkgs-lib-extensions) plus
      # every input's lib contribution, normalized to an OVERLAY
      # (final: prev: delta): `libOverlays.default` is the canonical export
      # and wins when both exist; the legacy `extendLib` endomorphism
      # (lib -> newLib) is wrapped -- its whole result merges over prev, so
      # it composes identically but cannot reference `final`. Both forms are
      # governed by the `extendLib` channel of inputContributions (one
      # lib-extension channel, whichever shape the input exports).
      # `channelEnabled` FIRST, like the `lib` channel below: behind the
      # export guards a malformed selection on an input exporting neither
      # form would be silently dropped instead of throwing.
      libOverlaysFromInputs = baseLib.concatLists (
        baseLib.mapAttrsToList (
          name: v:
          if !(channelEnabled name "extendLib" (caseOf name)) || !(baseLib.isAttrs v) then
            [ ]
          else if baseLib.isAttrs (v.libOverlays or null) && v.libOverlays ? default then
            [ v.libOverlays.default ]
          else if v ? extendLib then
            [ (final: prev: v.extendLib prev) ]
          else
            [ ]
        ) conventionInputs
      );

      # Only the MODULE-LEVEL half of this repo's lib goes into the system
      # lib, merged under the "existing side wins" rule. Both the split and
      # the rule live in ./module-level.nix, because the flake's own
      # `extendLib` and `overlays.default` must apply the identical one.
      ownAdditions = addOwnLib baseLib self;

      extendedLib = baseLib.foldl' (acc: overlay: acc.extend overlay) (baseLib.extend (
        final: prev: ownAdditions
      )) libOverlaysFromInputs;

      # Each input's standalone `lib` export, namespaced by input name:
      # exposed as `lib.<name>` in modules and as `pkgs.lib.<name>` (e.g.
      # `lib.NixVirt.domain`). A plain `lib` export is a foreign namespace
      # and is never merged flat -- `extendLib` remains the composable way
      # into the flat lib. Skipped: nixpkgs trees (their lib IS the base).
      libsFromInputs =
        let
          raw = baseLib.mapAttrs (_: libOf) (
            baseLib.filterAttrs (
              name: v:
              # `libOf` absorbs an input whose `lib` THROWS -- it is simply
              # not namespaced rather than breaking every host. The
              # selection check stays OUTSIDE it, so a malformed selection
              # still throws instead of being swallowed as "not namespaced".
              channelEnabled name "lib" (caseOf name) && baseLib.isAttrs v && libOf v != { } && !(isNixpkgsTree v)
            ) conventionInputs
          );
        in
        # The consuming flake's own lib output (inputs.self) is renamed to
        # `flake`: `lib.flake.<helper>` reads as "from this flake", where
        # `lib.self` would read oddly. An explicit input actually named
        # `flake` keeps the name; self's lib is then dropped with a warning.
        if raw ? self && !(raw ? flake) then
          builtins.removeAttrs raw [ "self" ] // { flake = raw.self; }
        else if raw ? self then
          builtins.warn
            "nixpkgs-lib-extensions: not exposing the consuming flake's `lib` as `lib.flake`: an input named `flake` already claims the name. Rename that input, or free the name with `inputContributions.\"flake\".lib = null;`."
            (builtins.removeAttrs raw [ "self" ])
        else
          raw;

      # Namespaces this repo OWNS: this lib's own namespaces that nixpkgs'
      # lib does not also define (e.g. `disko`, `nixos`, `imports` -- but
      # not `strings` or `attrsets`, which exist in nixpkgs too). These are
      # the only legitimate merge targets for an input's lib export.
      # tryEval: the deprecation TOMBSTONES on `self` (renamed builders) are
      # `throw` values, and a plain isAttrs would force them here -- a
      # tombstone is by construction not a namespace.
      ownedNamespaces = builtins.filter (
        n:
        let
          probe = builtins.tryEval (baseLib.isAttrs self.${n});
        in
        probe.success && probe.value && !(baseLib ? ${n})
      ) (builtins.attrNames self);

      # Overwrite detection, per collision class:
      # - name unused              -> input lib added as `lib.<name>`
      # - name is an OWNED namespace -> recursive merge, the existing side
      #   wins every conflict: an input can only ADD, never change (so a
      #   `disko` input's helpers join declareZfsRootDisk under lib.disko)
      # - any other existing name (nixpkgs's `strings`, ...) -> skipped
      #   with a warning; such an input name is almost always an accident
      # Computed ONCE per context and shared by the module lib, pkgs.lib
      # and every pkgs-* variant, so a warning fires once per context, not
      # once per lib construction.
      inputLibAdditions =
        let
          existing = builtins.intersectAttrs extendedLib libsFromInputs;
          owned = builtins.intersectAttrs (baseLib.genAttrs ownedNamespaces (_: null)) existing;
          skipped = builtins.attrNames (builtins.removeAttrs existing (builtins.attrNames owned));
        in
        (
          if skipped == [ ] then
            x: x
          else
            builtins.warn "nixpkgs-lib-extensions: not namespacing the `lib` export of input(s) ${builtins.concatStringsSep ", " skipped}: the name collides with a `lib` attribute this repo does not own. Rename the input to expose its lib as `lib.<name>`, or silence this with `inputContributions.\"<name>\".lib = null;` if you never wanted it namespaced."
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

      # Optionally apply patches to a nixpkgs source tree. Used for the
      # PRIMARY nixpkgs only -- see mkPkgs. The copy is named `source`, not
      # something descriptive: the patched tree becomes
      # `nixpkgs.flake.source` (mk-system.nix), and a NIX_PATH `<nixpkgs>`
      # lookup only works when the store path is named "source"
      # (https://github.com/NixOS/nix/issues/7075, quoted by the option).
      patchSrc =
        npkgs:
        if patches == [ ] then
          npkgs
        else
          npkgs.legacyPackages.${system}.applyPatches {
            name = "source";
            src = npkgs;
            inherit patches;
          };

      # `skipFor` is the only per-channel special-casing, and the asymmetry
      # in it is intentional: nixpkgs trees are skipped for modules (their
      # nixosModules are system-breaking helpers, and nixpkgs itself would
      # hit the ambiguity throw on every host) and for the lib namespacing
      # (a tree's lib IS the base lib), but NOT for overlays -- nixpkgs
      # exports none, and a fork exporting `overlays.default` means it to be
      # applied. Pinned by the tree-input assertions in
      # checks/builders/tests/auto-loading.nix; do not "fix" for symmetry.
      autoOverlays = collected.overlays;

      # `src` is the tree to import, ALREADY patched (or not) by the caller:
      # `patches` are a fix for THIS host's nixpkgs, and a nixpkgs PR diff
      # essentially never applies to a different tree. Applying them to the
      # `nixpkgs-*` variants too broke `pkgs-unstable` lazily, far from the
      # `patches = [ ... ]` line and only for hosts that touched it.
      mkPkgs =
        src:
        import src {
          inherit system;
          # the input-lib namespacing overlay sits between the collected
          # input overlays and the caller's extraOverlays, so extraOverlays
          # can still override pkgs.lib entirely
          overlays =
            autoOverlays ++ [ (final: prev: { lib = prev.lib // inputLibAdditions; }) ] ++ extraOverlays;
          config = pkgsConfig;
        };

      selectedSrc = patchSrc nixpkgs;
      # seq: `pkgs` is forced by every consumer, so hanging the eager
      # selection validation off it makes a typo fail on any use of the
      # context rather than only where its channel happens to be collected.
      pkgs = builtins.seq selectionsChecked (mkPkgs selectedSrc);

      home-manager = if homeManager != null then homeManager else detectHomeManager inputs;

      # Identity (store path) of the home-manager input, so its NixOS module is
      # kept out of the auto-collected set no matter how the input is named.
      homeManagerId = if home-manager == null then null else home-manager.outPath or null;

      # Skip when auto-collecting NixOS modules (absent a selection):
      # - the home-manager input (used standalone; matched by identity, not name)
      # - nixpkgs trees (isNixpkgsTree): they export helper modules like
      #   `readOnlyPkgs` that would break the system when imported blindly.
      #   `legacyPackages` alone is not enough to skip -- flakes like
      #   sops-nix export it (docs/packages) while also shipping a real
      #   `nixosModules.default` that must be imported.
      # To opt an input out by hand, select nothing for the channel:
      # `inputContributions."<name>".nixosModules = null;`
      skipNixosModule =
        name: v: (homeManagerId != null && (v.outPath or null) == homeManagerId) || isNixpkgsTree v;

      autoNixosModules = collected.nixosModules;
      autoHomeModules = collected.homeModules;

      # Every other `nixpkgs-*` input, keyed by variant (nixpkgs-unstable ->
      # unstable), with the same overlays and config as the primary but
      # WITHOUT `patches`: those target this host's own nixpkgs revision and
      # would fail to apply to a different tree. Canonically exposed as the
      # `nixpkgsLibExtensions.channels.<variant>` option; the legacy
      # `pkgs-<variant>` specialArgs below are derived from this same table
      # and stay until the planned breaking release.
      channels =
        lib.mapAttrs' (name: np: lib.nameValuePair (lib.removePrefix "nixpkgs-" name) (mkPkgs np))
          (
            lib.filterAttrs (
              name: v: lib.hasPrefix "nixpkgs-" name && lib.isAttrs v && v ? legacyPackages
            ) inputs
          );
      pkgsFromInputs = lib.mapAttrs' (name: lib.nameValuePair "pkgs-${name}") channels;

      # Every input's packages, pre-selected for this system: e.g.
      # `inputPkgs.disko.disko-install`. Deliberately NOT merged into `pkgs`
      # (input names would silently shadow nixpkgs attributes); an input's own
      # `overlays.default` -- which IS auto-applied -- is the flake author's
      # sanctioned way into `pkgs`.
      inputPkgs = lib.mapAttrs (_: v: v.packages.${system}) (
        lib.filterAttrs (_: v: lib.isAttrs v && (v.packages or { }) ? ${system}) inputs
      );
    in
    {
      inherit
        lib
        pkgs
        selectedSrc
        home-manager
        autoOverlays
        autoNixosModules
        autoHomeModules
        channels
        pkgsFromInputs
        inputPkgs
        inputLibAdditions
        ;
      # For mk-system.nix's choice of evaluation route: the nixpkgs INPUT
      # (unpatched -- when it is a flake, its lib.nixosSystem is the entry
      # point of choice) and whether `patches` forced a rebuilt tree
      # (selectedSrc is then a derivation, not the input).
      nixpkgsInput = nixpkgs;
      nixpkgsPatched = patches != [ ];
    };

  # Shared context: everything the builders need (lib, pkgs, specialArgs and the
  # auto-collected module/overlay sets). Builder-specific arguments are ignored
  # here via `...`. Adds the per-host layer (mySpecialArguments) on top of a
  # context core, which arrives as the FIRST parameter: `null` to compute one
  # from these arguments, or a core planHosts already built from the same
  # ones, so hosts agreeing on the core arguments share one nixpkgs
  # evaluation.
  #
  # It used to arrive as a `_core` KEY in the argument attrset, which meant it
  # was reachable from any public builder call: the argument allowlist had to
  # wave every `_`-prefixed key through, and a core needed a marker attribute
  # plus a throw so a hand-passed one could not silently swap the package set
  # the whole system is built from. As a parameter of an internal function it
  # is simply out of reach, and all three could go.
  mkContextCoreOrGiven = core: args: if core == null then mkContextCore args else core;

  mkContext =
    givenCore:
    {
      inputs,
      hostname,
      specialArgs ? { },
      # a throw, not a silent nonsense default: without inputs.self the
      # old `./.` fallback pointed INSIDE this library's own store tree,
      # so the hosts/<hostname> convention searched the wrong repo
      rootPath ? (
        inputs.self
          or (throw "nixpkgs-lib-extensions: `rootPath` was not given and `inputs.self` is missing, so the hosts/<hostname> convention and the rootPath specialArg have no root. Pass `rootPath` explicitly or include `self` in `inputs`.")
      ),
      ...
    }@args:
    let
      # A STALE core -- one built from DIFFERENT arguments than these -- is
      # still not detectable here, which is why planHosts is the only caller
      # that ever passes one.
      core = mkContextCoreOrGiven givenCore args;

      # Only the true import-time values remain specialArgs: the whole
      # `inputs` set (so modules can reach anything the generic conventions
      # do not cover, e.g. inputs.fenix -- the lib carries no per-input
      # special cases), `rootPath`, `extLib`, and the legacy `pkgs-*`
      # variants (canonical home: the `nixpkgsLibExtensions.channels`
      # option; the specialArgs stay until the planned breaking release).
      # Everything else the builder derives lives in the always-imported
      # `nixpkgsLibExtensions` options module (./ext-options.nix), where
      # values merge, carry types and are guarded by the module system.
      # Note: `pkgs` deliberately not included — modules already receive it from
      # the module system, and `specialArgs.pkgs` would override that wiring
      # (nixpkgs warns about it).
      builderOwned = {
        inherit inputs rootPath;
        # the specialArg keeps its user-facing name; its value is the lib
        # loader's fixed point
        extLib = self;
      }
      // core.pkgsFromInputs;

      # Shadowing a builder-owned name used to "work" and produce a
      # split-brain host: `specialArgs.hostname = "other"` reached modules
      # while networking.hostName kept the real one, and `rootPath` silently
      # moved the hosts/<host> file lookup. So: say so. Everything NOT
      # reserved here still passes through freely.
      # The MOVED names (./ext-options.nix) stay reserved too: a specialArg
      # of one would mask its `_module.args` tombstone and let modules read
      # a value the `nixpkgsLibExtensions` options do not hold -- the same
      # split brain wearing a new name. `username` is layered AFTER
      # specialArgs by both home mechanisms, so a specialArg of that name
      # would be silently discarded; reserved so it throws like the rest.
      reserved =
        builderOwned
        // movedSpecialArgs
        // {
          username = null;
        };
      shadowed = builtins.attrNames (builtins.intersectAttrs reserved specialArgs);
      shadowCheck =
        if shadowed == [ ] then
          null
        else
          throw ''
            nixpkgs-lib-extensions: host `${hostname}`: specialArgs may not redefine the reserved name(s) ${builtins.concatStringsSep ", " shadowed}. `inputs`, `rootPath`, `extLib` and the `pkgs-*` variants are builder-owned -- derived from the builder's own arguments, so overriding them here changes what MODULES see without changing what the builder did. `hostname`, `tags`, `hostGroup`, `listOfUsernames`, `inputPkgs` and `username` are not specialArgs anymore at all: modules read the `nixpkgsLibExtensions.*` options (and `config.networking.hostName` / the `username` module argument) instead. Set the corresponding builder argument, or pick a different specialArg name.
          '';

      # `specialArgs` already carries any per-host `extra.specialArgs`,
      # merged by planHosts before the builder ever sees it.
      mySpecialArguments = builtins.seq shadowCheck (builderOwned // specialArgs);
    in
    {
      inherit (core)
        lib
        pkgs
        selectedSrc
        home-manager
        autoNixosModules
        autoHomeModules
        inputPkgs
        channels
        nixpkgsInput
        nixpkgsPatched
        ;
      inherit mySpecialArguments;
    };
in
{
  inherit
    coreArgNames
    coreDefaults
    mkContextCore
    mkContext
    ;
}
