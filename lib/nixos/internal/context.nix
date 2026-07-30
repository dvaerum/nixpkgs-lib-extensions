# The shared evaluation context of the lib/nixos builders: `mkContext`
# assembles everything a builder needs (lib, pkgs, specialArgs and the
# auto-collected module/overlay sets) from one argument attrset. One of the
# four concern-files aggregated by ./shared.nix.
#
# The context is built in two layers:
#   mkContextCore  the host-INDEPENDENT part, a function of the core
#                  arguments only (coreArgNames below) -- this is where
#                  the expensive `import nixpkgs { ... }` happens
#   mkContext      the per-host layer on top (mySpecialArguments); it
#                  either computes a core itself or reuses one passed in
#                  via the internal `_core` argument, which is how
#                  buildNixosConfigurations/buildHomeConfigurations share
#                  ONE core across all hosts that stick to the defaults
#
# Like the builder files it is a function of `extLib` — the fully
# assembled nixpkgs-lib-extensions lib.
extLib:
let
  inherit (import ./inputs.nix extLib)
    detectHomeManager
    libOf
    channelEnabled
    collectFromInputs
    isNixpkgsTree
    ;

  # The argument names mkContextCore consumes -- everything the
  # host-independent part of the context depends on. The build* functions
  # use this list to decide whether a host entry may share the defaults'
  # core: only when it overrides NONE of these.
  #
  # DERIVED, not transcribed. As a hand-written list it was a silent
  # correctness hazard: add a parameter to mkContextCore below, forget the
  # list, and every host overriding that parameter quietly shares a core
  # built WITHOUT it -- the argument looks applied and is not. `functionArgs`
  # reads the formals of the lambda without forcing its body, so this cannot
  # drift.
  coreArgNames = builtins.attrNames (builtins.functionArgs mkContextCore);

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
      patches ? [ ],
      extraOverlays ? [ ],
      allowedUnfreePackages ? [ ],
      permittedInsecurePackages ? [ ],
      nixpkgsConfig ? { },
      homeManager ? null,
      inputContributions ? { },
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

      # Extend the system lib with this repo's own extensions (`extLib`, always
      # available since the builders are part of nixpkgs-lib-extensions) plus any
      # other input that exposes an `extendLib` function.
      # `channelEnabled` FIRST, like the `lib` channel below: behind the
      # `v ? extendLib` guard a malformed selection on an input that exports
      # no extendLib would be silently dropped instead of throwing.
      libExtenders = baseLib.concatLists (
        baseLib.mapAttrsToList (
          name: v:
          baseLib.optional (
            channelEnabled name "extendLib" (caseOf name) && baseLib.isAttrs v && v ? extendLib
          ) v.extendLib
        ) conventionInputs
      );
      extendedLib = baseLib.foldl' (acc: ext: acc.extend (final: prev: ext prev)) (baseLib.extend (
        final: prev: baseLib.recursiveUpdate prev extLib
      )) libExtenders;

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
      # PRIMARY nixpkgs only -- see mkPkgs.
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

      # Expose every other `nixpkgs-*` input as a `pkgs-*` specialArg, with
      # the same overlays and config as the primary (e.g. nixpkgs-unstable ->
      # pkgs-unstable) but WITHOUT `patches`: those target this host's own
      # nixpkgs revision and would fail to apply to a different tree.
      pkgsFromInputs =
        lib.mapAttrs' (name: np: lib.nameValuePair "pkgs-${lib.removePrefix "nixpkgs-" name}" (mkPkgs np))
          (
            lib.filterAttrs (
              name: v: lib.hasPrefix "nixpkgs-" name && lib.isAttrs v && v ? legacyPackages
            ) inputs
          );

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
      # marker: mkContext refuses a `_core` it did not produce, so a
      # hand-passed one cannot silently swap the package set the whole
      # system is built from
      __mkContextCore = true;
      inherit
        lib
        pkgs
        selectedSrc
        home-manager
        autoOverlays
        autoNixosModules
        autoHomeModules
        pkgsFromInputs
        inputPkgs
        inputLibAdditions
        ;
    };

  # Shared context: everything the builders need (lib, pkgs, specialArgs and the
  # auto-collected module/overlay sets). Builder-specific arguments are ignored
  # here via `...`. Adds the per-host layer (mySpecialArguments) on top of a
  # context core -- one passed in via `_core` (internal plumbing of the
  # build* functions; MUST have been built from the same core arguments),
  # or computed here from the arguments otherwise.
  mkContext =
    {
      inputs,
      hostname,
      tags ? [ ],
      specialArgs ? { },
      hostGroup ? null,
      # a throw, not a silent nonsense default: without inputs.self the
      # old `./.` fallback pointed INSIDE this library's own store tree,
      # so the hosts/<hostname> convention searched the wrong repo
      rootPath ? (
        inputs.self
          or (throw "nixpkgs-lib-extensions: `rootPath` was not given and `inputs.self` is missing, so the hosts/<hostname> convention and the rootPath specialArg have no root. Pass `rootPath` explicitly or include `self` in `inputs`.")
      ),
      _core ? null,
      ...
    }@args:
    let
      # `_core` is internal plumbing between planHosts and the builders, and
      # the ONE thing a consumer must not be able to do is hand in a core
      # built from different arguments -- the system would then be built
      # against a `pkgs` that has nothing to do with what it asked for, with
      # no error anywhere. mkContextCore stamps every core it produces;
      # anything else is refused. (It cannot catch a STALE core of our own,
      # which is why planHosts is the only thing that ever passes one.)
      core =
        if _core == null then
          mkContextCore args
        else if _core.__mkContextCore or false then
          _core
        else
          throw "nixpkgs-lib-extensions: `_core` is internal plumbing of buildConfigurations/buildNixosConfigurations/buildHomeConfigurations and must not be passed by hand; it selects the package set the whole system is built from.";

      # The whole `inputs` set is exposed so modules can reach anything not
      # covered by the generic conventions (e.g. inputs.fenix) themselves --
      # the lib carries no per-input special cases.
      # Note: `pkgs` deliberately not included — modules already receive it from
      # the module system, and `specialArgs.pkgs` would override that wiring
      # (nixpkgs warns about it).
      builderOwned = {
        inherit
          hostname
          inputs
          rootPath
          tags
          extLib
          hostGroup
          ;
        inherit (core) inputPkgs;
      }
      // core.pkgsFromInputs;

      # Shadowing a builder-owned name used to "work" and produce a
      # split-brain host: `specialArgs.hostname = "other"` reached modules
      # while networking.hostName kept the real one, and `rootPath` /
      # `hostGroup` silently moved the hosts/<host> file lookup. The
      # override promise was never true anyway -- `listOfUsernames` and
      # `username` are layered after specialArgs and cannot be overridden.
      # So: say so. Everything NOT owned here still passes through freely.
      shadowed = builtins.attrNames (builtins.intersectAttrs builderOwned specialArgs);
      shadowCheck =
        if shadowed == [ ] then
          null
        else
          throw ''
            nixpkgs-lib-extensions: host `${hostname}`: specialArgs may not redefine the builder-owned name(s) ${builtins.concatStringsSep ", " shadowed}. They are derived from the builder's own arguments, and overriding them here changes what MODULES see without changing what the builder did -- e.g. a `hostname` specialArg leaves networking.hostName and the hosts/<hostname> lookup on the real name. Set the corresponding builder argument instead, or pick a different specialArg name.
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
        ;
      inherit mySpecialArguments;
    };
in
{
  inherit coreArgNames mkContextCore mkContext;
}
