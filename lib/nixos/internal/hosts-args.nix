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
    discoverHostsForUser
    filterUsers
    ;
  inherit (import ./inputs.nix { inherit lib self; }) detectHomeManager;

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
  # default, `extra.<key>` ADDS to it. It replaced the two `additional*`
  # twins, which layered only `modules` and `specialArgs` out of the full
  # `allowedDefaultArgs` list and left no way to say "the shared home
  # modules PLUS these" at all.
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
      # No `_`-prefix escape hatch. It existed so planHosts could pass
      # `_core` through this very allowlist; the core is an explicit
      # parameter of the internal mkSystem/mkHome now, so every unknown key
      # is reported -- including a `_defaults` written inside a host entry
      # instead of beside it, which used to be accepted and ignored.
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
  # buildConfigurations)
  # and split it into { defaults, hostEntries }. The throwing face of
  # hostsProblems -- same division of labor as
  # builderArgProblems/validateBuilderArgs -- so the thrown text and the
  # problems-as-data can never disagree. Complains, naming fnName, about:
  # a non-allowlisted `_defaults` key (with special explanations for
  # `hostname` and `extra`), a non-allowlisted host entry key, or a host
  # entry whose inner `hostname` conflicts with its attribute key (a
  # redundant EQUAL one is tolerated).
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
  # buildHomeConfigurations each used to compute their own core from the
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
      usersTree = resolveUsers {
        ref =
          if (split.defaults.loginFlakeRef or null) != null then
            split.defaults.loginFlakeRef
          else
            (split.defaults.rootPath or (split.defaults.inputs.self or null));
        label = fnName;
        traceDiscoveredUsers = split.defaults.traceDiscoveredUsers or true;
      };
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
      # A host's EFFECTIVE core-argument tuple: every core argument made
      # explicit -- what the merged arguments state, over the builder's own
      # defaults. Compared over effective VALUES, not presence: a host
      # restating `inherit inputs system;` or writing a documented default
      # (`patches = [ ]`, ...) -- the most natural things to write -- must
      # still share. `coreDefaults` is mkContextCore's OWN defaults table
      # (context.nix), so the comparison cannot disagree with what
      # mkContextCore would build; `nixpkgs` is the one COMPUTED default
      # and is filled in from the host's `inputs`.
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
      # key conflict, anything else is replaced -- the same semantics the
      # two `additional*` twins had, generalised to every argument.
      combine =
        hostname: key: base: add:
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
        # it also used to catch base and add being DIFFERENT container
        # kinds, which is never a deliberate "add" -- it silently threw the
        # fleet-wide base away.
        else if lib.isList base != lib.isList add || lib.isAttrs base != lib.isAttrs add then
          throw "${fnName}: host `${hostname}`: `extra.${key}` is a ${builtins.typeOf add} but the value it must add to is a ${builtins.typeOf base}. `extra` ADDS to the merged value (lists concatenate, attrsets merge); to replace it outright, set `${key}` directly on the host."
        else
          add;
      applyExtra =
        hostname: merged: extra:
        lib.foldl' (
          acc: k:
          acc
          // {
            ${k} = if acc ? ${k} then combine hostname k acc.${k} extra.${k} else extra.${k};
          }
        ) merged (lib.attrNames extra);
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
          base = applyExtra hostname (split.defaults // (lib.removeAttrs groupLayer [ "extra" ])) (
            groupLayer.extra or { }
          );
        in
        applyExtra hostname (base // (lib.removeAttrs entry [ "extra" ]) // { inherit hostname; }) (
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
      # Normalized ONCE here so every consumer of the plan sees the
      # SAME tree for every consumer of the plan, scanned ONCE (see
      # `usersTree` above) rather than per host -- mk-system.nix/mk-home.nix
      # take it from here via `args.usersTree` instead of rescanning.
      registry = usersTree;
    }) mergedArgs;

  # A loginHomes typo is otherwise silent: the home flips to the
  # system-managed mechanism and everything still builds and boots. Only
  # checkable from a PLAN, where every host's registry is in view -- a name
  # that matches no user on one host is legal, a name no registry mentions
  # at all is a typo.
  planLoginUsers =
    fnName: plan:
    validateLoginUsers fnName (
      lib.attrValues (
        lib.mapAttrs (hostname: p: {
          inherit hostname;
          registry = p.registry;
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
      tree = resolveUsers {
        ref =
          if (checked.loginFlakeRef or null) != null then
            checked.loginFlakeRef
          else
            (checked.rootPath or (checked.inputs.self or null));
        label = fnName;
        traceDiscoveredUsers = checked.traceDiscoveredUsers or true;
      };
      homeFor =
        username: hostname:
        mkHome core (
          checked
          // {
            inherit username hostname;
            usersTree = tree;
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
  # costs no extra nixpkgs evaluation. A host-less home uses the
  # core of whichever host sorts first -- they share one core class in
  # the common case, and a host-less home has no host of its own to take
  # one from.
  userHomesFromPlan =
    fnName: plan:
    lib.seq (planLoginUsers fnName plan) (
      let
        anyHost = lib.head (lib.attrNames plan);
        tree = if plan == { } then { } else plan.${anyHost}.registry;
        # a plan whose hosts have no home-manager contributes nothing; an
        # explicit `homeManager` counts as having one WITHOUT re-running
        # detection -- that argument exists to bypass it.
        hasHomeManager =
          p: (p.args.homeManager or null) != null || detectHomeManager (p.args.inputs or { }) != null;

        # host-less homes, one per user with a home.nix of their own
        bare = lib.listToAttrs (
          map (u: {
            name = u;
            value = mkHome plan.${anyHost}.core (
              plan.${anyHost}.args
              // {
                username = u;
                hostname = null;
                usersTree = tree;
              }
            );
          }) (lib.filter (u: (resolveUser tree null u).homeModules != [ ]) (lib.attrNames tree))
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
              map (u: {
                name = "${u}@${hostname}";
                value = mkHome p.core (
                  p.args
                  // {
                    username = u;
                    inherit hostname;
                    usersTree = tree;
                  }
                );
              }) (lib.filter (u: (resolveUser hostTree hostname u).homeModules != [ ]) usersHere)
            )
        ) { } (lib.attrNames plan);
      in
      if plan == { } || !(hasHomeManager plan.${anyHost}) then { } else bare // perHost
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
    ;
}
