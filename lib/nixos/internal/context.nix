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
    classifyCase
    resolveEntrySet
    channelEnabled
    validateCases
    builtinInputSpecialCases
    normalizeInput
    isNixpkgsTree
    ;

  # Deduplicate the PATH elements of a collected module/overlay list,
  # keeping every non-path element as-is (order preserved). A blanket
  # `lib.unique` would deep-compare attrset modules, which can THROW when
  # two distinct modules carry functions at the same attribute path; only
  # paths have a cheap, reliable identity, so only they are deduplicated
  # (the module system tolerates the rare duplicated attrset module fine).
  uniquePaths =
    list:
    (builtins.foldl'
      (
        acc: x:
        if !(builtins.isPath x) then
          acc // { out = acc.out ++ [ x ]; }
        else if builtins.elem x acc.seen then
          acc
        else
          {
            seen = acc.seen ++ [ x ];
            out = acc.out ++ [ x ];
          }
      )
      {
        seen = [ ];
        out = [ ];
      }
      list
    ).out;

  # The argument names mkContextCore consumes -- everything the
  # host-independent part of the context depends on. The build* functions
  # use this list to decide whether a host entry may share the defaults'
  # core: only when it overrides NONE of these.
  coreArgNames = [
    "inputs"
    "system"
    "nixpkgs"
    "patches"
    "extraOverlays"
    "allowedUnfreePackages"
    "permittedInsecurePackages"
    "nixpkgsConfig"
    "homeManager"
    "inputSpecialCases"
  ];

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
      inputSpecialCases ? { },
      ...
    }:
    let
      baseLib = nixpkgs.lib;

      # ── how each input's automatic contributions are resolved ──
      #
      # ONE seam for every channel: the consumer's cases (validated against
      # the actual input names) are classified per input, the FUNCTION form
      # reshapes the input itself (conventionInputs), and the SELECTION forms
      # are answered per channel below. The `inputs`/`inputPkgs` specialArgs
      # stay raw: an input that contributes nothing automatically is still
      # reachable by hand.
      cases = builtinInputSpecialCases // (validateCases inputs inputSpecialCases);
      conventionInputs = builtins.mapAttrs (normalizeInput cases) inputs;
      caseOf = classifyCase cases;

      # Collect one entry-set channel across every input: locate the input's
      # exports for the channel, then let resolveEntrySet choose from them.
      # The built-in `skip` rules are consulted ONLY when no selection was
      # given -- they exist to stop the builder from GUESSING, and naming an
      # entry is the opposite of a guess.
      collectChannel =
        channel: locate: skip:
        uniquePaths (
          baseLib.concatLists (
            baseLib.mapAttrsToList (
              name: v:
              let
                case = caseOf name;
                selected = case.selections ? ${channel};
              in
              if !(baseLib.isAttrs v) || (!selected && skip name v) then
                [ ]
              else
                resolveEntrySet name channel (locate v) case
            ) conventionInputs
          )
        );

      # Entry-name validation must not depend on whether this particular
      # builder happens to COLLECT the channel: a `homeModules` typo on a
      # host with no system-managed homes, or a `nixosModules` typo in
      # homeConfigurationsBuilder, would otherwise never be forced -- while
      # the docs promise every typo fails loudly. So every selection the
      # consumer actually wrote is resolved here, eagerly. Scoped to the
      # inputs they named, so nothing else is probed (which also keeps the
      # deprecated `homeManagerModules` alias untouched on inputs the
      # consumer never mentioned). `length` forces the list's shape, never
      # the entries themselves, so catalog tombstones stay unforced.
      selectionsChecked =
        let
          locators = {
            nixosModules = v: v.nixosModules or { };
            homeModules = v: v.homeModules or v.homeManagerModules or { };
            overlays = v: v.overlays or { };
          };
          probe =
            name: _:
            let
              case = caseOf name;
              v = conventionInputs.${name};
            in
            baseLib.optionals (baseLib.isAttrs v) (
              baseLib.mapAttrsToList (
                channel: locate: builtins.length (resolveEntrySet name channel (locate v) case)
              ) (builtins.intersectAttrs case.selections locators)
            );
        in
        builtins.deepSeq (baseLib.concatLists (baseLib.mapAttrsToList probe inputSpecialCases)) null;

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
          raw = baseLib.mapAttrs (_: v: v.lib) (
            baseLib.filterAttrs (
              name: v:
              # tryEval: an input whose `lib` THROWS must not break every
              # host; it is simply not namespaced. The selection check sits
              # OUTSIDE the probe, so a malformed selection still throws
              # instead of being swallowed as "not namespaced".
              let
                probe = builtins.tryEval (
                  baseLib.isAttrs v && baseLib.isAttrs (v.lib or null) && !(isNixpkgsTree v)
                );
              in
              channelEnabled name "lib" (caseOf name) && probe.success && probe.value
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
            "nixpkgs-lib-extensions: not exposing the consuming flake's `lib` as `lib.flake`: an input named `flake` already claims the name."
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
            builtins.warn "nixpkgs-lib-extensions: not namespacing the `lib` export of input(s) ${builtins.concatStringsSep ", " skipped}: the name collides with a `lib` attribute this repo does not own. Rename the input to expose its lib as `lib.<name>`."
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

      # Auto-collect overlays (package extensions) from every input exposing
      # `overlays`. Deliberately NO built-in skips, where nixosModules and the
      # lib namespacing both skip nixpkgs trees. The asymmetry is intentional,
      # not an oversight -- both of those skips answer a hazard specific to
      # their channel:
      #   modules: a tree's nixosModules are system-breaking helpers
      #            (readOnlyPkgs, notDetected), and nixpkgs itself would hit
      #            the ambiguity throw on every single host without the skip.
      #   lib:     a tree's lib IS the base lib, so namespacing it would only
      #            duplicate it as lib.nixpkgs-unstable.mkIf and friends.
      # Neither reason reaches overlays: nixpkgs exports none at all, and a
      # FORK that deliberately exports `overlays.default` means it to be
      # applied. A tree shipping a CATALOG of overlays is already handled
      # loudly by the ambiguity throw, and inputSpecialCases can opt any
      # channel out per input. Pinned by the tree-input assertions in
      # checks/builders/tests/auto-loading.nix -- do not "fix" this for
      # symmetry.
      autoOverlays = collectChannel "overlays" (v: v.overlays or { }) (_: _: false);

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
      # seq: `pkgs` is forced by every consumer, so hanging the eager
      # selection validation off it makes a typo fail on any use of the
      # context rather than only where its channel happens to be collected.
      pkgs = builtins.seq selectionsChecked (mkPkgs nixpkgs);

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
      # `inputSpecialCases."<name>".nixosModules = null;`
      skipNixosModule =
        name: v: (homeManagerId != null && (v.outPath or null) == homeManagerId) || isNixpkgsTree v;

      # Auto-collect NixOS modules from every input exposing `nixosModules`.
      autoNixosModules = collectChannel "nixosModules" (v: v.nixosModules or { }) skipNixosModule;

      # Auto-collect home-manager modules from inputs exposing them under the
      # `homeModules` convention, falling back to the older
      # `homeManagerModules` name only when `homeModules` is absent --
      # flakes like plasma-manager keep `homeManagerModules` as a
      # deprecation alias that WARNS on access, so it must not be touched
      # when the new name exists.
      autoHomeModules = collectChannel "homeModules" (v: v.homeModules or v.homeManagerModules or { }) (
        _: _: false
      );

      # Expose every other `nixpkgs-*` input as a `pkgs-*` specialArg, built the
      # same way as the primary (e.g. nixpkgs-unstable -> pkgs-unstable).
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
      additionalSpecialArgs ? { },
      systemType ? null,
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
      core = if _core != null then _core else mkContextCore args;

      # The whole `inputs` set is exposed so modules can reach anything not
      # covered by the generic conventions (e.g. inputs.fenix) themselves --
      # the lib carries no per-input special cases.
      # Note: `pkgs` deliberately not included — modules already receive it from
      # the module system, and `specialArgs.pkgs` would override that wiring
      # (nixpkgs warns about it).
      mySpecialArguments = {
        inherit
          hostname
          inputs
          rootPath
          tags
          extLib
          systemType
          ;
        inherit (core) inputPkgs;
      }
      // core.pkgsFromInputs
      // specialArgs
      # the per-host extension slot: layered after specialArgs so that
      # `_defaults.specialArgs` and a host's additionalSpecialArgs combine
      # (mirroring modules/additionalModules)
      // additionalSpecialArgs;
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
