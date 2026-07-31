# Argument validation for the lib/nixos builders: the shared argument
# allowlists, direct-call validation and the hosts-attrset splitting used
# by buildNixosConfigurations/buildHomeConfigurations. One of the four
# concern-files aggregated by ./shared.nix.
#
# Like the builder files it is a function of `extLib` — the fully
# assembled nixpkgs-lib-extensions lib (unused here, but every internal
# file keeps the same shape so their imports stay uniform).
extLib:
let
  # for lowercasing the first character of a suggested key name
  upperAZ = [
    "A"
    "B"
    "C"
    "D"
    "E"
    "F"
    "G"
    "H"
    "I"
    "J"
    "K"
    "L"
    "M"
    "N"
    "O"
    "P"
    "Q"
    "R"
    "S"
    "T"
    "U"
    "V"
    "W"
    "X"
    "Y"
    "Z"
  ];
  lowerAZ = [
    "a"
    "b"
    "c"
    "d"
    "e"
    "f"
    "g"
    "h"
    "i"
    "j"
    "k"
    "l"
    "m"
    "n"
    "o"
    "p"
    "q"
    "r"
    "s"
    "t"
    "u"
    "v"
    "w"
    "x"
    "y"
    "z"
  ];

  inherit (import ./context.nix extLib) coreArgNames mkContextCore;
  inherit (import ./registry.nix extLib) validateLoginUsers validateRegistryKeys loginUsersWithHome;
  inherit (import ./inputs.nix extLib) detectHomeManager;

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
    "hostGroup"
    "patches"
    "extraOverlays"
    "allowedUnfreePackages"
    "permittedInsecurePackages"
    "nixpkgsConfig"
    "specialArgs"
    "homeManager"
    "inputContributions"
  ];
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
      bad = builtins.filter (k: !(builtins.elem k allowed) && builtins.substring 0 1 k != "_") (
        builtins.attrNames args
      );
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
          + " Accepted: ${builtins.concatStringsSep ", " allowed}."
        )
      ];

  # Direct-call argument validation for the singular builders: the same
  # rigor splitHostsArgs applies to hosts attrsets, at the other door --
  # otherwise the `...` patterns silently swallow typos and stale names.
  # `extraAllowed` covers builder-specific keys (e.g. `username`);
  # _-prefixed keys are internal plumbing and always pass.
  validateBuilderArgs =
    fnName: extraAllowed: args:
    let
      problems = builderArgProblems fnName extraAllowed args;
    in
    if problems == [ ] then args else throw (builtins.concatStringsSep "\n" problems);

  # Validate a hosts attrset (the shared input of both build* functions)
  # and split it into { defaults, hostEntries }. Throws, naming fnName,
  # on: a non-allowlisted `_defaults` key (with special explanations for
  # `hostname` and the `additional*` per-host halves), a non-allowlisted
  # host entry key, or a host entry whose inner `hostname` conflicts
  # with its attribute key (a redundant EQUAL one is tolerated).
  splitHostsArgs =
    fnName: hosts:
    let
      rawDefaults = hosts._defaults or { };
      # A hostname cannot START with `_`, which is what makes `_defaults`
      # safe as a reserved key -- but nothing enforced the other direction,
      # so `_default` / `_Defaults` / `_defualts` silently became a HOST and
      # took every real host's shared arguments with it.
      badReserved =
        map
          (
            k:
            "- `${k}`: keys starting with `_` are reserved; a hostname cannot start with one. Did you mean `_defaults`?"
          )
          (
            builtins.filter (k: k != "_defaults" && builtins.substring 0 1 k == "_") (builtins.attrNames hosts)
          );
      # A non-attrset `_defaults` otherwise dies inside builtins.attrNames
      # with no mention of which flake, function or key is at fault.
      defaults =
        if builtins.isAttrs rawDefaults then
          rawDefaults
        else
          throw "${fnName}: `_defaults` must be an attribute set of builder arguments, but is a value of type `${builtins.typeOf rawDefaults}`.";
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
        else
          "- `${name}`: not a builder argument (typo?). `_defaults` accepts: ${builtins.concatStringsSep ", " allowedDefaultArgs}.";
      badDefaults = map defaultComplaint (
        builtins.filter (k: !(builtins.elem k allowedDefaultArgs)) (builtins.attrNames defaults)
      );
      # every `_`-prefixed key is reserved, so none of them is ever a host
      hostEntries = builtins.removeAttrs hosts (
        builtins.filter (k: builtins.substring 0 1 k == "_") (builtins.attrNames hosts)
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
                "- `${hostname}`: `${k}` is not a builder argument (typo?). Host entries accept: ${builtins.concatStringsSep ", " allowedHostArgs}."
              ) (builtins.filter (k: !(builtins.elem k allowedHostArgs)) (builtins.attrNames args))
              ++
                map
                  (
                    k:
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
      problems = badReserved ++ badDefaults ++ badHostShapes ++ badHostKeys;
    in
    if problems != [ ] then
      throw ''
        ${fnName}: invalid hosts attrset:
        ${builtins.concatStringsSep "\n" problems}
      ''
    else
      { inherit defaults hostEntries; };

  # The complaints a hosts attrset would produce, as DATA. Same reason as
  # builderArgProblems: `builtins.tryEval` discards the message, so an
  # assertion that only checks "did it throw" is satisfied by ANY failure
  # in the expression and stays green against the wrong error forever.
  # These messages are the library's main UX surface -- test them.
  hostsProblems =
    fnName: hosts:
    let
      probe = builtins.tryEval (splitHostsArgs fnName hosts);
    in
    if probe.success then
      [ ]
    else
      # re-derive rather than parse the thrown string: the same inputs, minus
      # the throw
      let
        rawDefaults = hosts._defaults or { };
      in
      if !(builtins.isAttrs rawDefaults) then
        [
          "${fnName}: `_defaults` must be an attribute set of builder arguments, but is a value of type `${builtins.typeOf rawDefaults}`."
        ]
      else
        (map
          (
            k:
            "- `${k}`: keys starting with `_` are reserved; a hostname cannot start with one. Did you mean `_defaults`?"
          )
          (
            builtins.filter (k: k != "_defaults" && builtins.substring 0 1 k == "_") (builtins.attrNames hosts)
          )
        )
        ++ (map (
          name:
          if name == "hostname" then
            "- `hostname`: never a default -- it comes from each attribute key. Drop it."
          else if builtins.substring 0 10 name == "additional" then
            "- `${name}`: the `additional*` arguments are gone. Put the shared value in `_defaults` and the per-host addition in that host's `extra` slot -- a bare key replaces, `extra.<key>` adds."
          else
            "- `${name}`: not a builder argument (typo?). `_defaults` accepts: ${builtins.concatStringsSep ", " allowedDefaultArgs}."
        ) (builtins.filter (k: !(builtins.elem k allowedDefaultArgs)) (builtins.attrNames rawDefaults)));

  # ONE plan per hosts attrset, shared by every hosts-level builder: split
  # and validate, merge `_defaults` under each entry, and decide once
  # whether the host can reuse the defaults' context core. Returns
  # `{ <hostname> = { args; core; }; }` with `core = null` meaning "build
  # your own from args".
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
      defaultsCore = mkContextCore split.defaults;
      coreArgSet = builtins.listToAttrs (
        map (n: {
          name = n;
          value = null;
        }) coreArgNames
      );
      # A host shares the defaults' core when every core argument it
      # mentions resolves to the SAME VALUE the defaults would give. Mere
      # PRESENCE used to disqualify it, so writing `inherit inputs system;`
      # inside each host entry -- the most natural thing to write --
      # silently gave every host its own nixpkgs evaluation.
      #
      # Compared against the EFFECTIVE default, not against `null`: when
      # `_defaults` omits a core argument, a host writing the builder's own
      # documented default (`nixpkgsConfig = { }`, `extraOverlays = [ ]`,
      # `patches = [ ]`) would otherwise be compared with null and lose the
      # core for documenting itself.
      coreDefaults = builtins.functionArgs mkContextCore;
      effectiveDefault =
        n:
        if split.defaults ? ${n} then
          { v = split.defaults.${n}; }
        # functionArgs reports `true` for a formal WITH a default but cannot
        # give its value, so only the ones we can name are compared.
        else if n == "nixpkgsConfig" then
          { v = { }; }
        else if n == "extraOverlays" || n == "patches" || n == "allowedUnfreePackages" then
          { v = [ ]; }
        else if n == "permittedInsecurePackages" then
          { v = [ ]; }
        else if n == "inputContributions" then
          { v = { }; }
        else if n == "homeManager" then
          { v = null; }
        else
          null;
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
      sharesCore =
        entry:
        # `extra` touching a core argument always means a new core: it ADDS
        # to the default, so the result differs by construction.
        builtins.intersectAttrs coreArgSet (entry.extra or { }) == { }
        && builtins.all (
          n:
          let
            d = effectiveDefault n;
          in
          d != null && sameValue entry.${n} d.v
        ) (builtins.attrNames (builtins.intersectAttrs coreArgSet entry));

      # A bare key replaces; `extra.<key>` adds to whatever the merge
      # produced. Lists concatenate, attrsets merge with `extra` winning a
      # key conflict, anything else is replaced -- the same semantics the
      # two `additional*` twins had, generalised to every argument.
      # like lib.recursiveUpdate, which internal files cannot reach
      recursiveUpdateAttrs =
        lhs: rhs:
        lhs
        // builtins.mapAttrs (
          k: v:
          if builtins.isAttrs v && builtins.isAttrs (lhs.${k} or null) then
            recursiveUpdateAttrs lhs.${k} v
          else
            v
        ) rhs;
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
          recursiveUpdateAttrs base add
        # `else add` is right for scalars (hostGroup, userModule, ...), but
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
    in
    builtins.mapAttrs (
      hostname: entry:
      let
        args = applyExtra hostname (
          split.defaults // (builtins.removeAttrs entry [ "extra" ]) // { inherit hostname; }
        ) (entry.extra or { });
        rawRegistry = args.userRegistry or { };
      in
      {
        inherit args;
        # ALWAYS a core, never null. With null the builder recomputed one --
        # and so did EVERY homeConfigurationsBuilder call for that host, so
        # a non-sharing host with 4 login homes paid for 5 nixpkgs
        # evaluations. Computing it once per plan entry moves that back to
        # one. Lazy, so a host nobody forces still costs nothing.
        core = if sharesCore entry then defaultsCore else mkContextCore args;
        # `null` is a documented value for userRegistry; normalized ONCE
        # here so every consumer of the plan sees an attrset.
        registry = if rawRegistry == null then { } else rawRegistry;
      }
    ) split.hostEntries;

  # A plan entry's arguments with its context core attached. `_core` is
  # internal plumbing, never something a consumer writes -- mkContext
  # refuses one it did not produce.
  withCore = p: p.args // { _core = p.core; };

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
    builtins.seq (planLoginUsers fnName plan) (
      builtins.mapAttrs (_: p: extLib.nixosConfigurationsBuilder (withCore p)) plan
    );

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
              value = extLib.homeConfigurationsBuilder (withCore p // { inherit username; });
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
