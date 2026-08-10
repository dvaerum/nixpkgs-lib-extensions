# Argument validation for the lib/nixos builders: the shared argument
# allowlists, direct-call validation and the hosts-attrset splitting used
# by buildNixosConfigurations/buildHomeConfigurations. One of the
# concern-files aggregated by ./shared.nix.
#
# Takes the loader's `{ lib, self, ... }`: nixpkgs' lib, and the fully
# assembled nixpkgs-lib-extensions lib.
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
    validateRegistryKeys
    loginUsersWithHome
    ;
  inherit (import ./inputs.nix { inherit lib self; }) detectHomeManager;

  # ONE hosts attrset is meant to feed BOTH buildNixosConfigurations and
  # buildHomeConfigurations, so both validate against the same allowlists:
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
    "userRegistry"
    "loginHomes"
    "homeModules"
    "loginFlakeRef"
    "loginReactivateEveryLogin"
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

  # Arguments renamed in 1.0.0: old name -> new name. The old names are
  # tombstones at every door a builder argument can enter (direct calls,
  # `_defaults`, host entries, `extra`): the complaint names the
  # replacement instead of calling the name a typo.
  renamedArgs = {
    extraOverlays = "overlays";
    hostGroup = "group";
  };
  renamedComplaint =
    name:
    "`${name}` was renamed to `${renamedArgs.${name}}` in 1.0.0 -- same behavior, new name (see CHANGELOG.md).";
  # `extra` is the ONE per-host layering slot: a bare key REPLACES the
  # default, `extra.<key>` ADDS to it. It replaced the two `additional*`
  # twins, which layered exactly two of the 21 arguments and left no way to
  # say "the shared home modules PLUS these" at all.
  allowedHostArgs = allowedDefaultArgs ++ [
    "hostname"
    "extra"
  ];

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
      allowed = builtins.filter (k: k != "extra") allowedHostArgs ++ extraAllowed;
      # No `_`-prefix escape hatch. It existed so planHosts could pass
      # `_core` through this very allowlist; the core is an explicit
      # parameter of the internal mkSystem/mkHome now, so every unknown key
      # is reported -- including a `_defaults` written inside a host entry
      # instead of beside it, which used to be accepted and ignored.
      bad = builtins.filter (k: !(builtins.elem k allowed)) (builtins.attrNames args);
    in
    if bad == [ ] then
      [ ]
    else
      [
        (
          "${fnName}: unknown argument(s): ${builtins.concatStringsSep ", " bad} (typo?)."
          + (
            if builtins.elem "extra" bad then
              " `extra` is a per-host layering slot of the hosts attrset that buildConfigurations/buildNixosConfigurations take; a direct call receives the merged arguments, so pass them directly."
            else
              ""
          )
          # a RENAMED name deserves its pointer, not just the typo verdict
          + builtins.concatStringsSep "" (
            map (n: " ${renamedComplaint n}") (builtins.filter (n: renamedArgs ? ${n}) bad)
          )
          + " Accepted: ${builtins.concatStringsSep ", " allowed}."
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
    if problems == [ ] then args else throw (builtins.concatStringsSep "\n" problems);

  # every `_`-prefixed key is reserved, so none of them is ever a host
  hostEntriesOf =
    hosts:
    builtins.removeAttrs hosts (
      builtins.filter (k: builtins.substring 0 1 k == "_") (builtins.attrNames hosts)
    );

  # The complaints a hosts attrset raises, as DATA -- the COMPLETE list,
  # all four classes (reserved keys, `_defaults` keys, host-entry shapes,
  # host-entry keys); splitHostsArgs throws exactly what this returns.
  # Exported for the tests, same reason as builderArgProblems:
  # `builtins.tryEval` discards the message, so an assertion that only
  # checks "did it throw" is satisfied by ANY failure in the expression and
  # stays green against the wrong error forever. These messages are the
  # library's main UX surface -- test them.
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
            builtins.filter (k: k != "_defaults" && k != "_groups" && builtins.substring 0 1 k == "_") (
              builtins.attrNames hosts
            )
          );
      defaultComplaint =
        name:
        if name == "hostname" then
          "- `hostname`: never a default -- it comes from each attribute key. Drop it."
        else if builtins.substring 0 10 name == "additional" then
          "- `${name}`: the `additional*` arguments are gone. Put the shared value in `_defaults` and the per-host addition in that host's `extra` slot: `extra.${
            builtins.substring 10 (-1) name
          } = [ ... ];` (a bare key replaces, `extra.<key>` adds)."
        else if name == "extra" then
          "- `extra`: the per-host layering slot, never a default -- `_defaults` holds the base values that `extra` adds to."
        else if renamedArgs ? ${name} then
          "- ${renamedComplaint name}"
        else
          "- `${name}`: not a builder argument (typo?). `_defaults` accepts: ${builtins.concatStringsSep ", " allowedDefaultArgs}.";
      badDefaults = map defaultComplaint (
        builtins.filter (k: !(builtins.elem k allowedDefaultArgs)) (builtins.attrNames rawDefaults)
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
        else if builtins.elem name allowedDefaultArgs then
          null
        else if renamedArgs ? ${name} then
          "- `_groups.${groupName}`: ${renamedComplaint name}"
        else
          "- `_groups.${groupName}`: `${name}` is not a builder argument (typo?). Group entries accept the same names as `_defaults`, plus `extra`.";
      badGroups = builtins.concatLists (
        builtins.attrValues (
          builtins.mapAttrs (
            groupName: entry:
            if !(builtins.isAttrs entry) then
              [
                "- `_groups.${groupName}`: must be an attribute set of builder arguments, but is a value of type `${builtins.typeOf entry}`."
              ]
            else if entry ? extra && !(builtins.isAttrs entry.extra) then
              [
                "- `_groups.${groupName}`: `extra` must be an attribute set of builder arguments to ADD, but is a value of type `${builtins.typeOf entry.extra}`."
              ]
            else
              builtins.filter (c: c != null) (
                map (groupComplaint groupName) (builtins.attrNames entry)
                ++ map (
                  k:
                  if k == "group" || !(builtins.elem k allowedDefaultArgs) then
                    "- `_groups.${groupName}`: `extra.${k}` is not a builder argument (typo?). `extra` accepts the same names as `_defaults` (minus `group`)."
                  else
                    null
                ) (builtins.attrNames (if builtins.isAttrs (entry.extra or { }) then entry.extra or { } else { }))
              )
          ) rawGroups
        )
      );
      hostEntries = hostEntriesOf hosts;
      # The group a host would take its `_groups` layer from -- the same
      # precedence planHosts applies (a host's own `group`, else the
      # `_defaults` one; `extra.group`, a scalar add, replaces). Judged
      # here so a typo'd group name is reported WITH the other complaints
      # instead of surfacing as a missing layer.
      effectiveGroupOf =
        args:
        if builtins.isAttrs (args.extra or null) && args.extra ? group then
          args.extra.group
        else
          args.group or (rawDefaults.group or null);
      badGroupRefs =
        if !(hosts ? _groups) then
          [ ]
        else
          builtins.concatLists (
            builtins.attrValues (
              builtins.mapAttrs (
                hostname: args:
                let
                  g = if builtins.isAttrs args then effectiveGroupOf args else null;
                in
                if g == null then
                  [ ]
                else if !(builtins.isString g) then
                  [
                    "- `${hostname}`: `group` must be a string naming a `_groups` entry, but is a value of type `${builtins.typeOf g}`."
                  ]
                else if !(builtins.isAttrs rawGroups) || rawGroups ? ${g} then
                  [ ]
                else
                  [
                    "- `${hostname}`: `group = \"${g}\"` names no `_groups` entry (typo?). Declared groups: ${
                      if rawGroups == { } then "(none)" else builtins.concatStringsSep ", " (builtins.attrNames rawGroups)
                    }."
                  ]
              ) hostEntries
            )
          );
      badHostShapes = builtins.concatLists (
        builtins.attrValues (
          builtins.mapAttrs (
            hostname: args:
            if !(builtins.isAttrs args) then
              [
                "- `${hostname}`: a host entry must be an attribute set of builder arguments, but is a value of type `${builtins.typeOf args}`. (The host's own configuration is found by convention at hosts/${hostname}.nix -- it is not passed here.)"
              ]
            else if args ? extra && !(builtins.isAttrs args.extra) then
              [
                "- `${hostname}`: `extra` must be an attribute set of builder arguments to ADD, but is a value of type `${builtins.typeOf args.extra}`."
              ]
            else
              [ ]
          ) hostEntries
        )
      );
      badHostKeys = builtins.concatLists (
        builtins.attrValues (
          builtins.mapAttrs (
            hostname: args:
            if !(builtins.isAttrs args) then
              [ ]
            else
              map (
                k:
                if renamedArgs ? ${k} then
                  "- `${hostname}`: ${renamedComplaint k}"
                else
                  "- `${hostname}`: `${k}` is not a builder argument (typo?). Host entries accept: ${builtins.concatStringsSep ", " allowedHostArgs}."
              ) (builtins.filter (k: !(builtins.elem k allowedHostArgs)) (builtins.attrNames args))
              ++
                map
                  (
                    k:
                    if renamedArgs ? ${k} then
                      "- `${hostname}`: `extra.${k}`: ${renamedComplaint k}"
                    else
                      "- `${hostname}`: `extra.${k}` is not a builder argument (typo?). `extra` accepts the same names as `_defaults`."
                  )
                  (
                    builtins.filter (k: !(builtins.elem k allowedDefaultArgs)) (
                      # guarded: a non-attrset `extra` is reported by
                      # badHostShapes, and attrNames on it here would be an
                      # uncatchable TYPE error raised while the problem list is
                      # still being assembled
                      if builtins.isAttrs (args.extra or { }) then builtins.attrNames (args.extra or { }) else [ ]
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
    # builtins.attrNames with no mention of which flake, function or key is
    # at fault. The ONE complaint that preempts all others: nothing else
    # can be judged without reading those keys.
    if !(builtins.isAttrs rawDefaults) then
      [
        "${fnName}: `_defaults` must be an attribute set of builder arguments, but is a value of type `${builtins.typeOf rawDefaults}`."
      ]
    else if !(builtins.isAttrs rawGroups) then
      [
        "${fnName}: `_groups` must be an attribute set of group-name -> builder-argument sets, but is a value of type `${builtins.typeOf rawGroups}`."
      ]
    else
      badReserved ++ badDefaults ++ badGroups ++ badGroupRefs ++ badHostShapes ++ badHostKeys;

  # Validate a hosts attrset (the shared input of both build* functions)
  # and split it into { defaults, hostEntries }. The throwing face of
  # hostsProblems -- same division of labor as
  # builderArgProblems/validateBuilderArgs -- so the thrown text and the
  # problems-as-data can never disagree. Complains, naming fnName, about:
  # a non-allowlisted `_defaults` key (with special explanations for
  # `hostname` and the `additional*` per-host halves), a non-allowlisted
  # host entry key, or a host entry whose inner `hostname` conflicts
  # with its attribute key (a redundant EQUAL one is tolerated).
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
    else if
      !(builtins.isAttrs (hosts._defaults or { })) || !(builtins.isAttrs (hosts._groups or { }))
    then
      # already a complete sentence naming fnName; no list around it
      throw (builtins.head problems)
    else
      throw ''
        ${fnName}: invalid hosts attrset:
        ${builtins.concatStringsSep "\n" problems}
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
      coreArgSet = builtins.listToAttrs (
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
        if builtins.isAttrs a && builtins.isAttrs b && a ? outPath && b ? outPath then
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
        // builtins.intersectAttrs coreArgSet args;
      sameCoreArgs = a: b: builtins.all (n: sameValue (a.${n} or null) (b.${n} or null)) coreArgNames;

      # A bare key replaces; `extra.<key>` adds to whatever the merge
      # produced. Lists concatenate, attrsets merge with `extra` winning a
      # key conflict, anything else is replaced -- the same semantics the
      # two `additional*` twins had, generalised to every argument.
      combine =
        hostname: key: base: add:
        if builtins.isList base && builtins.isList add then
          base ++ add
        else if builtins.isAttrs base && builtins.isAttrs add then
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
        else if
          builtins.isList base != builtins.isList add || builtins.isAttrs base != builtins.isAttrs add
        then
          throw "${fnName}: host `${hostname}`: `extra.${key}` is a ${builtins.typeOf add} but the value it must add to is a ${builtins.typeOf base}. `extra` ADDS to the merged value (lists concatenate, attrsets merge); to replace it outright, set `${key}` directly on the host."
        else
          add;
      applyExtra =
        hostname: merged: extra:
        builtins.foldl' (
          acc: k:
          acc
          // {
            ${k} = if acc ? ${k} then combine hostname k acc.${k} extra.${k} else extra.${k};
          }
        ) merged (builtins.attrNames extra);
      # `_defaults` merged under each entry, the host's `_groups` layer (if
      # it declares a `group` that has one) BETWEEN the two, `extra` layered
      # on top -- the arguments each builder finally receives. The group
      # layer behaves like a host entry sitting under the real one: its bare
      # keys replace `_defaults` per argument, its `extra` ADDS to them, and
      # the host wins over the lot. The group is read from the FULLY merged
      # arguments (so `extra.group` counts, matching hostsProblems'
      # effectiveGroupOf), and validation has already established that it
      # names a `_groups` entry whenever `_groups` exists at all.
      mergedArgs = builtins.mapAttrs (
        hostname: entry:
        let
          merge =
            base:
            applyExtra hostname (base // (builtins.removeAttrs entry [ "extra" ]) // { inherit hostname; }) (
              entry.extra or { }
            );
          groupName = (merge split.defaults).group or null;
          groupLayer = if groupName == null then { } else split.groups.${groupName} or { };
          base = applyExtra hostname (split.defaults // (builtins.removeAttrs groupLayer [ "extra" ])) (
            groupLayer.extra or { }
          );
        in
        merge base
      ) split.hostEntries;
      coreTuples = builtins.mapAttrs (_: coreArgsOf) mergedArgs;

      # ONE core per equivalence class. Sharing used to be binary
      # (match `_defaults` exactly or pay a full nixpkgs evaluation), so
      # two aarch64 hosts in an x86 fleet each paid for the SAME deviation.
      # Eval time now scales with the number of DISTINCT core-argument
      # tuples, not with fleet size. The fold only ever compares tuples
      # (cheap: outPath identity first); each `mkContextCore` application
      # stays an unforced thunk until some host uses its class's core.
      coreClasses = builtins.foldl' (
        acc: hostname:
        let
          tuple = coreTuples.${hostname};
        in
        if builtins.any (c: sameCoreArgs c.tuple tuple) acc then
          acc
        else
          acc
          ++ [
            {
              inherit tuple;
              core = mkContextCore tuple;
            }
          ]
      ) [ ] (builtins.attrNames coreTuples);
      # total by construction: every host's tuple seeded a class above
      coreFor =
        hostname: (lib.findFirst (c: sameCoreArgs c.tuple coreTuples.${hostname}) null coreClasses).core;
    in
    builtins.mapAttrs (
      hostname: args:
      let
        rawRegistry = args.userRegistry or { };
      in
      {
        inherit args;
        # ALWAYS a core, never null. With null the builder recomputed one --
        # and so did EVERY mkHomeConfiguration call for that host, so
        # a non-sharing host with 4 login homes paid for 5 nixpkgs
        # evaluations. Computing it once per class moves that back to one.
        # Lazy: a host nobody forces costs nothing beyond tuple comparisons.
        core = coreFor hostname;
        # `null` is a documented value for userRegistry; normalized ONCE
        # here so every consumer of the plan sees an attrset.
        registry = if rawRegistry == null then { } else rawRegistry;
      }
    ) mergedArgs;

  # A loginHomes typo is otherwise silent: the home flips to the
  # system-managed mechanism and everything still builds and boots. Only
  # checkable from a PLAN, where every host's registry is in view -- a name
  # that matches no user on one host is legal, a name no registry mentions
  # at all is a typo.
  planLoginUsers =
    fnName: plan:
    builtins.seq (validateRegistryKeys fnName (map (p: p.registry) (builtins.attrValues plan)))
      validateLoginUsers
      fnName
      (
        builtins.attrValues (
          builtins.mapAttrs (hostname: p: {
            inherit hostname;
            registry = p.args.userRegistry or { };
            loginHomes = p.args.loginHomes or [ ];
          }) plan
        )
      );

  # The two projections of a plan. Kept here so buildNixosConfigurations,
  # buildHomeConfigurations and buildConfigurations are literally the same
  # code applied to the same plan.
  systemsFromPlan =
    fnName: plan:
    builtins.seq (planLoginUsers fnName plan) (builtins.mapAttrs (_: p: mkSystem p.core p.args) plan);

  homesFromPlan =
    fnName: plan:
    builtins.seq (planLoginUsers fnName plan) (
      builtins.foldl' (
        acc: hostname:
        let
          p = plan.${hostname};
          # login-managed users that actually ship a home.nix on this host
          usersHome = loginUsersWithHome p.registry hostname (p.args.loginHomes or [ ]);
        in
        # a host with no home-manager contributes nothing. An explicit
        # `homeManager` counts as having one WITHOUT re-running detection --
        # that argument exists to bypass it.
        if (p.args.homeManager or null) == null && detectHomeManager (p.args.inputs or { }) == null then
          acc
        else
          acc
          // builtins.listToAttrs (
            map (username: {
              name = "${username}@${hostname}";
              value = mkHome p.core (p.args // { inherit username; });
            }) usersHome
          )
      ) { } (builtins.attrNames plan)
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
    homesFromPlan
    ;
}
