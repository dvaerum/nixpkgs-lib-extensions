# Argument validation for the lib/nixos builders: the shared argument
# allowlists, direct-call validation and the hosts-attrset splitting used
# by buildNixosConfigurations/buildHomeConfigurations. One of the
# concern-files aggregated by ./shared.nix (which documents the shared
# `{ lib, self, ... }` calling convention).
{ lib, self, ... }:
let
  inherit (import ./context.nix { inherit lib self; })
    coreArgNames
    coreDefaults
    mkContextCore
    ;
  inherit (import ./mk-system.nix { inherit lib self; }) mkSystem;
  inherit (import ./mk-home.nix { inherit lib self; }) mkHome;
  inherit (import ./registry.nix { inherit lib self; })
    validateLoginUsers
    loginUsersWithHome
    resolveUser
    resolveUsers
    loginFlakeRefSources
    discoverHostsForUser
    filterUsers
    contextInputsAndRootPathFor
    ;
  inherit (import ./inputs.nix { inherit lib self; }) detectHomeManager;
  inherit (import ./user-defaults.nix { inherit lib self; })
    allowedUserDefaultsArgs
    allowedUserHostDefaultsArgs
    userDefaultsPath
    readUserDefaults
    ;

  # ---- argument-merge primitives, shared by planHosts' host layering and
  # userHomesStandalone/userHomesFromPlan's user layering below. Hoisted
  # out of planHosts (which used to be their only caller) rather than
  # transcribed a second time -- `fnName` becomes an explicit leading
  # argument in place of what used to be a closure.

  coreArgSet = lib.listToAttrs (
    map (n: {
      name = n;
      value = null;
    }) coreArgNames
  );
  # Cheap identity first: flake inputs carry `outPath`, so two of them
  # are the same tree iff those match. Plain `==` on genuinely different
  # same-size attrsets descends arbitrarily deep -- a probe comparing
  # two nixpkgs instantiations took ~6 seconds and forced thousands of
  # attributes this library is otherwise careful never to force.
  sameValue =
    a: b:
    if lib.isAttrs a && lib.isAttrs b && a ? outPath && b ? outPath then
      a.outPath == b.outPath
    else
      # `==` does NOT throw on functions (it returns false); tryEval is
      # here only for a `throw` embedded in the compared data.
      let
        probe = builtins.tryEval (a == b);
      in
      probe.success && probe.value;
  # A host's (or a user's) EFFECTIVE core-argument tuple: every core
  # argument made explicit -- what the merged arguments state, over the
  # builder's own defaults. Compared over effective VALUES, not presence:
  # restating `inherit inputs system;` or writing a documented default
  # (`patches = [ ]`, ...) -- the most natural things to write -- must
  # still share. `coreDefaults` is mkContextCore's OWN defaults table
  # (context.nix), so the comparison cannot disagree with what
  # mkContextCore would build; `nixpkgs` is the one COMPUTED default and
  # is filled in from the caller's `inputs`.
  coreArgsOf =
    args:
    coreDefaults
    // {
      nixpkgs = args.nixpkgs or (args.inputs.nixpkgs or null);
    }
    // lib.intersectAttrs coreArgSet args;
  sameCoreArgs = a: b: lib.all (n: sameValue (a.${n} or null) (b.${n} or null)) coreArgNames;

  # A bare key replaces; `extra.<key>` adds to whatever the merge
  # produced. Lists concatenate, attrsets merge with `extra` winning a
  # key conflict, anything else is replaced.
  combine =
    fnName: hostname: key: base: add:
    if lib.isList base && lib.isList add then
      base ++ add
    else if lib.isAttrs base && lib.isAttrs add then
      # recursiveUpdate, not `//`: `inputContributions` is two levels
      # (input -> channel), so a shallow merge let
      # `extra.inputContributions.vendor.overlays = null;` replace the
      # whole per-input entry and silently drop a sibling
      # `nixosModules` selection -- the wrong modules got imported with
      # no error, because the fallback rule happens to succeed.
      lib.recursiveUpdate base add
    # `else add` is right for scalars (group, userModule, ...), but
    # base and add being DIFFERENT container kinds is never a
    # deliberate "add" -- falling through to `add` silently threw the
    # fleet-wide base away.
    else if lib.isList base != lib.isList add || lib.isAttrs base != lib.isAttrs add then
      throw "${fnName}: host `${hostname}`: `extra.${key}` is a ${builtins.typeOf add} but the value it must add to is a ${builtins.typeOf base}. `extra` ADDS to the merged value (lists concatenate, attrsets merge); to replace it outright, set `${key}` directly on the host."
    else
      add;
  applyExtra =
    fnName: hostname: merged: extra:
    lib.foldl' (
      acc: k:
      acc
      // {
        ${k} = if acc ? ${k} then combine fnName hostname k acc.${k} extra.${k} else extra.${k};
      }
    ) merged (lib.attrNames extra);

  # ---- per-user layering (users/<u>/_defaults.nix, and its
  # users/<u>/hosts/<h>/_defaults.nix companion), used by
  # userHomesStandalone and userHomesFromPlan below.

  # The per-user override attrset, fully resolved: the base file (if any)
  # then the `hosts/<h>` override file (if any) layered on top with the
  # SAME semantics as above -- a bare key REPLACES, `extra.<key>` ADDS.
  # `hostname == null` (a host-less home) reads only the base file: there
  # is no override directory to layer, by construction.
  userOverridesFor =
    fnName: contextFor: baseDir: hostname:
    let
      base = readUserDefaults allowedUserDefaultsArgs false baseDir (contextFor hostname);
    in
    if hostname == null || baseDir == null then
      base
    else
      let
        hostDir = baseDir + "/hosts/${hostname}";
        hostOverrides = readUserDefaults allowedUserHostDefaultsArgs true hostDir (contextFor hostname);
      in
      applyExtra fnName (toString hostDir) (base // (lib.removeAttrs hostOverrides [ "extra" ])) (
        hostOverrides.extra or { }
      );

  # A user's overrides only need a core OF THEIR OWN when they touch a
  # CORE argument (coreArgNames) -- otherwise the shared core already in
  # hand is correct and reused, so most users cost nothing extra. Never
  # hands mkHome a core built from DIFFERENT arguments than the ones it
  # receives: context.nix documents that a stale core is undetectable,
  # and a per-user `system` on a REUSED core would silently pair the
  # host's `pkgs` with the user's own `home-manager` package.
  coreForOverrides =
    sharedCore: baseArgs: overrides:
    if lib.any (k: overrides ? ${k}) coreArgNames then
      mkContextCore (coreArgsOf (baseArgs // overrides))
    else
      sharedCore;

  # A host-less home's `system`: the user's own file wins; else the
  # fleet's `_defaults.system`; else this is genuinely undecidable --
  # refuse to guess (same posture as ambiguousExportMessage, inputs.nix).
  # `systemsInPlay` is only for the message.
  hostlessSystemOrThrow =
    fnName: username: defaultsSystem: systemsInPlay: overrides:
    if overrides ? system then
      overrides.system
    else if defaultsSystem != null then
      defaultsSystem
    else
      throw "${fnName}: hosts span ${lib.concatStringsSep ", " systemsInPlay} and no `_defaults.system` says which a host-less home should use -- `${username}` has no users/${username}/hosts/<host>/ directory to take an architecture from instead. Set `_defaults.system` (the fleet-wide default), or give ${username} a users/${username}/hosts/<host>/ directory so their home follows that host.";

  # `alice@laptop`'s `system` is decided TWICE if the user's own file
  # also sets it: once by the host (physical reality) and once by the
  # file. Silently preferring either is exactly the bug this file exists
  # to remove, so the two must AGREE -- never merely pick one.
  #
  # Exposed as DATA (like stringFlakeRefWarning/ambiguousExportMessage):
  # a throw's own text is not observable in-language, so tests pin this
  # by calling the message builder directly rather than catching the
  # real throw.
  hostSystemConflictMessage = fnName: username: hostname: hostSystem: userSystem: ''
    ${fnName}: home `${username}@${hostname}`: host `${hostname}` declares
    system = "${hostSystem}", but users/${username}/hosts/${hostname}/_defaults.nix
    sets system = "${userSystem}". A host's architecture is not a
    user's to choose. Fix by either:
      - dropping `system` from users/${username}/hosts/${hostname}/_defaults.nix, or
      - correcting `${hostname}`'s own `system` if the host really is ${userSystem}.
    (A user file's `system` applies to their host-less home, where there
     is no host to contradict.)
  '';

  # Returns `overrides` unchanged (a pass-through, like
  # validateBuilderArgs) so a call site can pipe it straight into the merge.
  checkHostSystemConflict =
    fnName: username: hostname: hostSystem: overrides:
    if overrides ? system && overrides.system != hostSystem then
      throw (hostSystemConflictMessage fnName username hostname hostSystem overrides.system)
    else
      overrides;

  # ONE hosts attrset is meant to feed BOTH buildNixosConfigurations and
  # buildConfigurations, so both validate against the same allowlists:
  # arguments only one side uses (modules, userModule, ...) are accepted
  # everywhere and ignored by the other side; homeModules is used by
  # BOTH (system-managed and login-managed homes).
  # Keep in sync with the documented argument lists (tested by
  # checks/builders/tests/defaults.nix).
  allowedDefaultArgs = [
    "inputs"
    "system"
    "nixpkgs"
    "rootPath"
    "modules"
    "userModule"
    "users"
    "loginHomes"
    "homeModules"
    "loginFlakeRef"
    "loginReactivateEveryLogin"
    "homeAutoUpgrade"
    "homeAutoUpgradeFlakeRef"
    "systemAutoUpgrade"
    "systemAutoUpgradeFlakeRef"
    "systemGarbageCollect"
    "traceDiscoveredUsers"
    "wrapHomeManagerSwitch"
    "tags"
    "group"
    "hostFolder"
    "patches"
    "overlays"
    "allowedUnfreePackages"
    "permittedInsecurePackages"
    "nixpkgsConfig"
    "specialArgs"
    "homeManager"
    "inputContributions"
  ];

  # `extra` is the ONE per-host layering slot: a bare key REPLACES the
  # default, `extra.<key>` ADDS to it -- for every argument in
  # `allowedDefaultArgs` except `group` (see `effectiveGroup` below), so
  # "the shared home modules PLUS these" is sayable for all of them, not
  # just a chosen few.
  allowedHostArgs = allowedDefaultArgs ++ [
    "hostname"
    "extra"
  ];

  # THE group a host resolves to: its own `group`, else the `_defaults`
  # one. The ONE definition shared by the validation (badGroupRefs) and
  # the planHosts merge, so the group that is checked against `_groups`
  # can never differ from the group whose layer is applied. `extra.group`
  # does not exist: nothing about `group` is additive, so it is forbidden
  # in every `extra` slot (host and `_groups` alike).
  effectiveGroup = defaults: args: args.group or (defaults.group or null);

  # The PROBLEMS with a direct builder call, as a list of strings -- empty
  # when there are none. Split out from the throwing wrapper below so the
  # tests can assert on the MESSAGE: `builtins.tryEval` discards it, so an
  # assertion that only checks "did it throw" is equally satisfied by an
  # unrelated failure elsewhere in the expression, and stays green forever
  # against the wrong error. The error text is this library's main UX
  # surface; it deserves to be tested, not just its existence.
  builderArgProblems =
    fnName: extraAllowed: args:
    let
      # `extra` is a HOSTS-ATTRSET key, resolved by planHosts before a
      # builder ever runs. A direct call takes the already-merged arguments,
      # so accepting it here would silently drop whatever it carried.
      allowed = lib.filter (k: k != "extra") allowedHostArgs ++ extraAllowed;
      # No `_`-prefix escape hatch: the core is an explicit parameter of
      # the internal mkSystem/mkHome (see ./mk-system.nix's header), so
      # every unknown key is reported -- including a `_defaults` written
      # inside a host entry instead of beside it.
      bad = lib.filter (k: !(lib.elem k allowed)) (lib.attrNames args);
    in
    if bad == [ ] then
      [ ]
    else
      [
        (
          "${fnName}: unknown argument(s): ${lib.concatStringsSep ", " bad} (typo?)."
          + (
            if lib.elem "extra" bad then
              " `extra` is a per-host layering slot of the hosts attrset that buildConfigurations/buildNixosConfigurations take; a direct call receives the merged arguments, so pass them directly."
            else
              ""
          )
          + " Accepted: ${lib.concatStringsSep ", " allowed}."
        )
      ];

  # Direct-call argument validation for the singular builders: the same
  # rigor splitHostsArgs applies to hosts attrsets, at the other door --
  # otherwise the `...` patterns silently swallow typos and stale names.
  # `extraAllowed` covers builder-specific keys (e.g. `username`).
  validateBuilderArgs =
    fnName: extraAllowed: args:
    let
      problems = builderArgProblems fnName extraAllowed args;
    in
    if problems == [ ] then args else throw (lib.concatStringsSep "\n" problems);

  # every `_`-prefixed key is reserved, so none of them is ever a host
  hostEntriesOf =
    hosts: lib.removeAttrs hosts (lib.filter (k: lib.substring 0 1 k == "_") (lib.attrNames hosts));

  # The complaints a hosts attrset raises, as DATA -- the COMPLETE list,
  # all four classes (reserved keys, `_defaults` keys, host-entry shapes,
  # host-entry keys); splitHostsArgs throws exactly what this returns.
  # Exported for the tests, same reason as builderArgProblems above.
  hostsProblems =
    fnName: hosts:
    let
      rawDefaults = hosts._defaults or { };
      rawGroups = hosts._groups or { };
      # A hostname cannot START with `_`, which is what makes `_defaults`
      # and `_groups` safe as reserved keys -- but nothing enforced the
      # other direction, so `_default` / `_Defaults` / `_defualts` silently
      # became a HOST and took every real host's shared arguments with it.
      badReserved =
        map
          (
            k:
            "- `${k}`: keys starting with `_` are reserved; a hostname cannot start with one. Did you mean `_defaults` or `_groups`?"
          )
          (
            lib.filter (k: k != "_defaults" && k != "_groups" && lib.substring 0 1 k == "_") (
              lib.attrNames hosts
            )
          );
      defaultComplaint =
        name:
        if name == "hostname" then
          "- `hostname`: never a default -- it comes from each attribute key. Drop it."
        else if name == "extra" then
          "- `extra`: the per-host layering slot, never a default -- `_defaults` holds the base values that `extra` adds to."
        else
          "- `${name}`: not a builder argument (typo?). `_defaults` accepts: ${lib.concatStringsSep ", " allowedDefaultArgs}.";
      badDefaults = map defaultComplaint (
        lib.filter (k: !(lib.elem k allowedDefaultArgs)) (lib.attrNames rawDefaults)
      );
      # `_groups.<name>` entries take the `_defaults` allowlist plus an
      # `extra` slot (layering onto `_defaults`, like a host's) -- minus
      # `group` itself: a group layer cannot re-classify, its attribute
      # name IS the group.
      groupComplaint =
        groupName: name:
        if name == "group" then
          "- `_groups.${groupName}`: a group layer cannot set `group` -- its attribute name IS the group; hosts opt in with `group = \"${groupName}\";`."
        else if name == "extra" then
          null
        else if lib.elem name allowedDefaultArgs then
          null
        else
          "- `_groups.${groupName}`: `${name}` is not a builder argument (typo?). Group entries accept the same names as `_defaults`, plus `extra`.";
      badGroups = lib.concatLists (
        lib.attrValues (
          lib.mapAttrs (
            groupName: entry:
            if !(lib.isAttrs entry) then
              [
                "- `_groups.${groupName}`: must be an attribute set of builder arguments, but is a value of type `${builtins.typeOf entry}`."
              ]
            else if entry ? extra && !(lib.isAttrs entry.extra) then
              [
                "- `_groups.${groupName}`: `extra` must be an attribute set of builder arguments to ADD, but is a value of type `${builtins.typeOf entry.extra}`."
              ]
            else
              lib.filter (c: c != null) (
                map (groupComplaint groupName) (lib.attrNames entry)
                ++ map (
                  k:
                  if k == "group" || !(lib.elem k allowedDefaultArgs) then
                    "- `_groups.${groupName}`: `extra.${k}` is not a builder argument (typo?). `extra` accepts the same names as `_defaults` (minus `group`)."
                  else
                    null
                ) (lib.attrNames (if lib.isAttrs (entry.extra or { }) then entry.extra or { } else { }))
              )
          ) rawGroups
        )
      );
      hostEntries = hostEntriesOf hosts;
      # A typo'd group name is judged here so it is reported WITH the other
      # complaints instead of surfacing as a missing layer. effectiveGroup
      # is the SAME function planHosts resolves the layer with.
      badGroupRefs =
        if !(hosts ? _groups) then
          [ ]
        else
          lib.concatLists (
            lib.attrValues (
              lib.mapAttrs (
                hostname: args:
                let
                  g = if lib.isAttrs args then effectiveGroup rawDefaults args else null;
                in
                if g == null then
                  [ ]
                else if !(lib.isString g) then
                  [
                    "- `${hostname}`: `group` must be a string naming a `_groups` entry, but is a value of type `${builtins.typeOf g}`."
                  ]
                else if !(lib.isAttrs rawGroups) || rawGroups ? ${g} then
                  [ ]
                else
                  [
                    "- `${hostname}`: `group = \"${g}\"` names no `_groups` entry (typo?). Declared groups: ${
                      if rawGroups == { } then "(none)" else lib.concatStringsSep ", " (lib.attrNames rawGroups)
                    }."
                  ]
              ) hostEntries
            )
          );
      badHostShapes = lib.concatLists (
        lib.attrValues (
          lib.mapAttrs (
            hostname: args:
            if !(lib.isAttrs args) then
              [
                "- `${hostname}`: a host entry must be an attribute set of builder arguments, but is a value of type `${builtins.typeOf args}`. (The host's own configuration is found by convention at hosts/${hostname}.nix -- it is not passed here.)"
              ]
            else if args ? extra && !(lib.isAttrs args.extra) then
              [
                "- `${hostname}`: `extra` must be an attribute set of builder arguments to ADD, but is a value of type `${builtins.typeOf args.extra}`."
              ]
            else
              [ ]
          ) hostEntries
        )
      );
      badHostKeys = lib.concatLists (
        lib.attrValues (
          lib.mapAttrs (
            hostname: args:
            if !(lib.isAttrs args) then
              [ ]
            else
              map (
                k:
                "- `${hostname}`: `${k}` is not a builder argument (typo?). Host entries accept: ${lib.concatStringsSep ", " allowedHostArgs}."
              ) (lib.filter (k: !(lib.elem k allowedHostArgs)) (lib.attrNames args))
              ++
                map
                  (
                    k:
                    if k == "group" then
                      # nothing about `group` is additive: `extra` ADDS to a
                      # merged value, and a scalar "add" is just a replace
                      # wearing the wrong slot
                      "- `${hostname}`: `extra.group` is not a thing -- `group` is a scalar, so there is nothing to ADD to. Set `group` directly on the host (it replaces the `_defaults` one)."
                    else
                      "- `${hostname}`: `extra.${k}` is not a builder argument (typo?). `extra` accepts the same names as `_defaults` (minus `group`)."
                  )
                  (
                    lib.filter (k: k == "group" || !(lib.elem k allowedDefaultArgs)) (
                      # guarded: a non-attrset `extra` is reported by
                      # badHostShapes, and attrNames on it here would be an
                      # uncatchable TYPE error raised while the problem list is
                      # still being assembled
                      if lib.isAttrs (args.extra or { }) then lib.attrNames (args.extra or { }) else [ ]
                    )
                  )
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
    in
    # A non-attrset `_defaults` (or `_groups`) otherwise dies inside
    # lib.attrNames with no mention of which flake, function or key is
    # at fault. The ONE complaint that preempts all others: nothing else
    # can be judged without reading those keys.
    if !(lib.isAttrs rawDefaults) then
      [
        "${fnName}: `_defaults` must be an attribute set of builder arguments, but is a value of type `${builtins.typeOf rawDefaults}`."
      ]
    else if !(lib.isAttrs rawGroups) then
      [
        "${fnName}: `_groups` must be an attribute set of group-name -> builder-argument sets, but is a value of type `${builtins.typeOf rawGroups}`."
      ]
    else
      badReserved ++ badDefaults ++ badGroups ++ badGroupRefs ++ badHostShapes ++ badHostKeys;

  # Validate a hosts attrset (the input of buildNixosConfigurations and
  # buildConfigurations) and split it into { defaults, hostEntries }. The
  # throwing face of hostsProblems -- same division of labor as
  # builderArgProblems/validateBuilderArgs -- so the thrown text and the
  # problems-as-data can never disagree.
  splitHostsArgs =
    fnName: hosts:
    let
      problems = hostsProblems fnName hosts;
    in
    if problems == [ ] then
      {
        defaults = hosts._defaults or { };
        groups = hosts._groups or { };
        hostEntries = hostEntriesOf hosts;
      }
    else if !(lib.isAttrs (hosts._defaults or { })) || !(lib.isAttrs (hosts._groups or { })) then
      # already a complete sentence naming fnName; no list around it
      throw (lib.head problems)
    else
      throw ''
        ${fnName}: invalid hosts attrset:
        ${lib.concatStringsSep "\n" problems}
      '';

  # ONE plan per hosts attrset, shared by every hosts-level builder: split
  # and validate, merge `_defaults` under each entry, and build ONE context
  # core per EQUIVALENCE CLASS of core arguments. Returns
  # `{ <hostname> = { args; core; registry; }; }`.
  #
  # Doing this once is not only deduplication: buildNixosConfigurations and
  # buildConfigurations each used to compute their own core from the
  # SAME `_defaults`, so the documented "define hosts once, pass to both"
  # pattern paid for two full nixpkgs evaluations. Nix memoizes
  # `import <path>` but never the application, so both were held live.
  planHosts =
    fnName: hosts:
    let
      split = splitHostsArgs fnName hosts;
      # ONE users-tree scan for the whole plan. Every host in a fleet
      # normally shares `_defaults`' inputs/loginFlakeRef, so scanning per
      # host would repeat identical work and (worse) repeat the discovery
      # trace once per host for one real scan.
      # `{ tree; untrustedUsers; }` -- the shape resolveUsers returns --
      # shared as-is via `registry`/`args.usersTree` below; mk-system.nix
      # and mk-home.nix each unwrap what they need.
      usersTree = resolveUsers {
        sources = loginFlakeRefSources (split.defaults.loginFlakeRef or null) (
          split.defaults.rootPath or (split.defaults.inputs.self or null)
        );
        label = fnName;
        traceDiscoveredUsers = split.defaults.traceDiscoveredUsers or true;
      };
      # `_defaults` merged under each entry, the host's `_groups` layer (if
      # it declares a `group` that has one) BETWEEN the two, `extra` layered
      # on top -- the arguments each builder finally receives. The group
      # layer behaves like a host entry sitting under the real one: its bare
      # keys replace `_defaults` per argument, its `extra` ADDS to them, and
      # the host wins over the lot. The group is resolved by the SAME
      # effectiveGroup that hostsProblems validated against, so it names a
      # `_groups` entry whenever `_groups` exists at all.
      mergedArgs = lib.mapAttrs (
        hostname: entry:
        let
          groupName = effectiveGroup split.defaults entry;
          groupLayer = if groupName == null then { } else split.groups.${groupName} or { };
          base = applyExtra fnName hostname (split.defaults // (lib.removeAttrs groupLayer [ "extra" ])) (
            groupLayer.extra or { }
          );
        in
        applyExtra fnName hostname (base // (lib.removeAttrs entry [ "extra" ]) // { inherit hostname; }) (
          entry.extra or { }
        )
      ) split.hostEntries;
      coreTuples = lib.mapAttrs (_: coreArgsOf) mergedArgs;

      # ONE core per equivalence class. Sharing used to be binary
      # (match `_defaults` exactly or pay a full nixpkgs evaluation), so
      # two aarch64 hosts in an x86 fleet each paid for the SAME deviation.
      # Eval time now scales with the number of DISTINCT core-argument
      # tuples, not with fleet size. The fold only ever compares tuples
      # (cheap: outPath identity first); each `mkContextCore` application
      # stays an unforced thunk until some host uses its class's core.
      coreClasses = lib.foldl' (
        acc: hostname:
        let
          tuple = coreTuples.${hostname};
        in
        if lib.any (c: sameCoreArgs c.tuple tuple) acc then
          acc
        else
          acc
          ++ [
            {
              inherit tuple;
              core = mkContextCore tuple;
            }
          ]
      ) [ ] (lib.attrNames coreTuples);
      # total by construction: every host's tuple seeded a class above
      coreFor =
        hostname: (lib.findFirst (c: sameCoreArgs c.tuple coreTuples.${hostname}) null coreClasses).core;
    in
    lib.mapAttrs (hostname: args: {
      inherit args;
      # ALWAYS a core, never null. With null the builder recomputed one --
      # and so did EVERY mkHomeConfiguration call for that host, so
      # a non-sharing host with 4 login homes paid for 5 nixpkgs
      # evaluations. Computing it once per class moves that back to one.
      # Lazy: a host nobody forces costs nothing beyond tuple comparisons.
      core = coreFor hostname;
      # Normalized ONCE here so every consumer of the plan sees the SAME
      # tree, scanned ONCE (see `usersTree` above) rather than per host --
      # mk-system.nix/mk-home.nix take it from here via `args.usersTree`
      # instead of rescanning.
      registry = usersTree;
    }) mergedArgs;

  # A loginHomes typo is otherwise silent (see validateLoginUsers in
  # registry.nix). Only checkable from a PLAN, where every host's registry
  # is in view -- a name that matches no user on one host is legal, a name
  # no registry mentions at all is a typo.
  planLoginUsers =
    fnName: plan:
    validateLoginUsers fnName (
      lib.attrValues (
        lib.mapAttrs (hostname: p: {
          inherit hostname;
          # bare tree -- validateLoginUsers/registryUserNames want
          # `{ username = path; }`, not the `{ tree; untrustedUsers; }`
          # wrapper p.registry carries (trust is irrelevant to a
          # loginHomes typo check).
          registry = p.registry.tree;
          loginHomes = p.args.loginHomes or [ ];
        }) plan
      )
    );

  # The two projections of a plan. Kept here so buildNixosConfigurations
  # and buildConfigurations are literally the same code applied to the
  # same plan. buildHomeConfigurations does NOT plan -- see
  # userHomesStandalone above.
  systemsFromPlan =
    fnName: plan:
    lib.seq (planLoginUsers fnName plan) (
      lib.mapAttrs (_: p: mkSystem p.core (p.args // { usersTree = p.registry; })) plan
    );

  # STANDALONE user-centric homes: no `hosts` attrset at all, so there is
  # no declared host list and no per-host build settings -- one flat
  # argument set, ONE context core, and the host dimension discovered
  # entirely from the users tree (`users/<u>/hosts/<h>/`).
  #
  # This is what a home-manager-only flake calls. A fleet that also builds
  # NixOS systems uses buildConfigurations instead, where per-host homes
  # reuse each host's own core (see userHomesFromPlan).
  userHomesStandalone =
    fnName: args:
    let
      checked = validateBuilderArgs fnName [ ] args;
      core = mkContextCore checked;
      # `resolved` is the `{ tree; untrustedUsers; }` shape resolveUsers
      # returns -- handed to mkHome as-is (it only reads `.tree`); `tree`
      # below is the bare `{ username = path; }` map this function's own
      # bare/pairs discovery needs.
      resolved = resolveUsers {
        sources = loginFlakeRefSources (checked.loginFlakeRef or null) (
          checked.rootPath or (checked.inputs.self or null)
        );
        label = fnName;
        traceDiscoveredUsers = checked.traceDiscoveredUsers or true;
      };
      tree = resolved.tree;
      # `users/<u>/_defaults.nix` (and its `hosts/<h>/_defaults.nix`
      # companion) merged on top of `checked`. Most users touch none of
      # this: `userOverridesFor` returns `{ }` when no file exists, and
      # `coreForOverrides` reuses the ONE `core` above unless an override
      # actually changes a core argument -- so a user with no file, or
      # one that only sets e.g. `homeModules`, costs nothing extra.
      homeFor =
        username: hostname:
        let
          # `inputs`/`rootPath` come from `username`'s OWN loginContext
          # when they were discovered from a foreign `loginFlakeRef`
          # source that declared one -- otherwise the caller's own, same
          # as before. Same bug class as home.nix/configuration.nix: a
          # `_defaults.nix` using `rootPath` needs the SOURCE's own tree.
          contextFor =
            hostname:
            (contextInputsAndRootPathFor fnName (resolved.userLoginContext or { }) username (checked.inputs) (
              checked.rootPath or (checked.inputs.self or null)
            ))
            // {
              extLib = self;
              inherit username hostname lib;
            };
          overrides = userOverridesFor fnName contextFor (tree.${username} or null) hostname;
          userCore = coreForOverrides core checked overrides;
        in
        mkHome userCore (
          checked
          // overrides
          // {
            inherit username hostname;
            usersTree = resolved;
          }
        );
      bare = lib.filter (u: (resolveUser tree null u).homeModules != [ ]) (lib.attrNames tree);
      pairs = lib.concatMap (
        u:
        map
          (h: {
            inherit u h;
          })
          (
            lib.filter (h: (resolveUser tree h u).homeModules != [ ]) (discoverHostsForUser (tree.${u} or null))
          )
      ) (lib.attrNames tree);
    in
    if detectHomeManager (checked.inputs or { }) == null && (checked.homeManager or null) == null then
      { }
    else
      lib.listToAttrs (
        map (u: {
          name = u;
          value = homeFor u null;
        }) bare
      )
      // lib.listToAttrs (
        map (e: {
          name = "${e.u}@${e.h}";
          value = homeFor e.u e.h;
        }) pairs
      );

  # USER-CENTRIC home projection. Users come from the plan's shared
  # users tree; the host dimension exists only where a user actually has
  # a `hosts/<hostname>` override directory:
  #
  #   users/dennis/home.nix               -> "dennis"
  #   users/dennis/hosts/laptop/home.nix  -> "dennis@laptop"
  #
  # Both keys when both exist: `"dennis"` is the default-anywhere profile
  # (buildable on a machine the tree has never heard of), `"dennis@laptop"`
  # is that profile with the laptop override merged on top. Suppressing
  # the bare key as soon as any `hosts/` folder appeared would mean adding
  # one machine-specific override silently removed the ability to
  # `switch --flake .#dennis` anywhere else.
  #
  # A `"<user>@<host>"` home is built against THAT host's core -- the same
  # `mkContextCore` thunk `systemsFromPlan` uses for its system, so it
  # costs no extra nixpkgs evaluation, UNLESS the user's own
  # `hosts/<h>/_defaults.nix` changes a core argument, in which case a
  # `system` conflicting with the host's own throws (a host's
  # architecture is physical reality, not a user's to override) and
  # anything else gets that user their own core. A host-less home has no
  # host to take a core from -- its `system` comes from its OWN
  # `_defaults.nix` if it has one, else the fleet's `_defaults.system`,
  # else building it throws rather than silently picking one (this used
  # to pick "whichever declared host sorts first alphabetically", which
  # changed a host-less home's architecture on an unrelated host rename;
  # see checks/builders/tests/user-defaults.nix for the regression this
  # closes).
  #
  # `hosts` is the RAW attrset `planHosts` built `plan` from -- needed for
  # its `_defaults`, which `plan` itself does not carry (a plan is keyed
  # by hostname only, and `_defaults` is not a hostname).
  userHomesFromPlan =
    fnName: plan: hosts:
    lib.seq (planLoginUsers fnName plan) (
      let
        # Safe here (unlike a core): `registry` is IDENTICAL on every
        # host in the plan by construction (planHosts's one shared
        # `usersTree` scan), so picking any one host to read it off of is
        # not the arbitrary-choice problem `system` was.
        firstHost = lib.head (lib.attrNames plan);
        registry =
          if plan == { } then
            {
              tree = { };
              untrustedUsers = [ ];
              userLoginContext = { };
            }
          else
            plan.${firstHost}.registry;
        tree = registry.tree;
        # a plan whose hosts have no home-manager contributes nothing; an
        # explicit `homeManager` counts as having one WITHOUT re-running
        # detection -- that argument exists to bypass it.
        hasHomeManager =
          p: (p.args.homeManager or null) != null || detectHomeManager (p.args.inputs or { }) != null;

        # `_defaults` alone, same as the plan's own users-tree scan
        # (planHosts) -- a host-less home is by definition not any one
        # host's concern, so only the fleet-wide layer is consulted, not
        # any host's merged args (which may differ per host precisely in
        # the ways that matter here: system, homeManager, inputs).
        defaultsArgs = hosts._defaults or { };
        defaultsSystem = defaultsArgs.system or null;
        systemsInPlay = lib.unique (map (h: plan.${h}.args.system) (lib.attrNames plan));
        hasHomeManagerFleetWide =
          (defaultsArgs.homeManager or null) != null
          || detectHomeManager (defaultsArgs.inputs or { }) != null;
        # Lazy, like every core: unforced unless some host-less home
        # with NO core-changing override of its own actually gets built.
        defaultsCore = mkContextCore (coreArgsOf (defaultsArgs // { system = defaultsSystem; }));

        # host-less homes, one per user with a home.nix of their own
        bare = lib.listToAttrs (
          map (
            u:
            let
              contextFor =
                hostname:
                (contextInputsAndRootPathFor fnName (registry.userLoginContext or { }) u (defaultsArgs.inputs or { }
                ) (defaultsArgs.rootPath or (defaultsArgs.inputs.self or null)))
                // {
                  extLib = self;
                  username = u;
                  inherit hostname lib;
                };
              overrides = userOverridesFor fnName contextFor (tree.${u} or null) null;
              effectiveSystem = hostlessSystemOrThrow fnName u defaultsSystem systemsInPlay overrides;
              finalArgs = defaultsArgs // overrides // { system = effectiveSystem; };
              # `lib.seq effectiveSystem` is load-bearing, not decoration:
              # `defaultsCore` was built from raw `defaultsSystem`, which
              # CAN be null (no fleet-wide default, this user's own file
              # sets none either). Reusing it unconditionally let a null
              # system reach `import nixpkgs` before `effectiveSystem`'s
              # own clean throw ever got forced -- nixpkgs' own
              # system-parsing then failed with an unrelated, confusing
              # "cannot coerce null to a string" instead. Forcing
              # `effectiveSystem` FIRST guarantees the intended throw
              # fires; reaching `defaultsCore` at all proves it didn't.
              userCore =
                if lib.any (k: overrides ? ${k}) coreArgNames then
                  mkContextCore (coreArgsOf finalArgs)
                else
                  lib.seq effectiveSystem defaultsCore;
            in
            {
              name = u;
              value = mkHome userCore (
                finalArgs
                // {
                  username = u;
                  hostname = null;
                  usersTree = registry;
                }
              );
            }
          ) (lib.filter (u: (resolveUser tree null u).homeModules != [ ]) (lib.attrNames tree))
        );

        # per-host homes, one per (user, hosts/<host>) override that a
        # DECLARED host in this plan matches
        perHost = lib.foldl' (
          acc: hostname:
          let
            p = plan.${hostname};
            # a host's own `users` filter narrows its homes as well as its
            # accounts, so `users = [ ]` really means "nothing here"
            # `users` is the host's own SELECTION list (a list of names),
            # not the tree -- the tree arrives as `p.registry` above.
            hostTree = filterUsers fnName hostname (p.args.users or null) tree;
            usersHere = lib.filter (u: lib.elem hostname (discoverHostsForUser (hostTree.${u} or null))) (
              lib.attrNames hostTree
            );
          in
          if !(hasHomeManager p) then
            acc
          else
            acc
            // lib.listToAttrs (
              map (
                u:
                let
                  contextFor =
                    hn:
                    (contextInputsAndRootPathFor fnName (registry.userLoginContext or { }) u (p.args.inputs or { }) (
                      p.args.rootPath or (p.args.inputs.self or null)
                    ))
                    // {
                      extLib = self;
                      username = u;
                      hostname = hn;
                      inherit lib;
                    };
                  rawOverrides = userOverridesFor fnName contextFor (hostTree.${u} or null) hostname;
                  # The host's OWN `system` wins any contest with the
                  # user's file -- checked here, not merely assumed by
                  # merge order, so the two disagreeing throws instead of
                  # one silently shadowing the other.
                  overrides = checkHostSystemConflict fnName u hostname p.args.system rawOverrides;
                  userCore = coreForOverrides p.core p.args overrides;
                in
                {
                  name = "${u}@${hostname}";
                  value = mkHome userCore (
                    p.args
                    // overrides
                    // {
                      username = u;
                      inherit hostname;
                      usersTree = registry;
                    }
                  );
                }
              ) (lib.filter (u: (resolveUser hostTree hostname u).homeModules != [ ]) usersHere)
            )
        ) { } (lib.attrNames plan);
      in
      if plan == { } || !hasHomeManagerFleetWide then { } else bare // perHost
    );

in
{
  inherit
    allowedDefaultArgs
    allowedHostArgs
    validateBuilderArgs
    builderArgProblems
    splitHostsArgs
    hostsProblems
    planHosts
    systemsFromPlan
    userHomesFromPlan
    userHomesStandalone
    hostSystemConflictMessage
    ;
}
