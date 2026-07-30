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
  inherit (import ./context.nix extLib) coreArgNames mkContextCore;
  inherit (import ./registry.nix extLib) validateLoginUsers loginUsersWithHome;
  inherit (import ./inputs.nix extLib) detectHomeManager;

  # ONE hosts attrset is meant to feed BOTH buildNixosConfigurations and
  # buildHomeConfigurations, so both validate against the same allowlists:
  # arguments only one side uses (modules, userModuleFn, ...) are accepted
  # everywhere and ignored by the other side; homeSharedModules is used by
  # BOTH (system-managed and login-managed homes).
  # Keep in sync with the documented argument lists (tested by
  # checks/builders/tests/defaults.nix).
  allowedDefaultArgs = [
    "inputs"
    "system"
    "nixpkgs"
    "rootPath"
    "modules"
    "userModuleFn"
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
    "homeManager"
    "inputSpecialCases"
  ];
  allowedHostArgs = allowedDefaultArgs ++ [
    "hostname"
    "additionalModules"
    "additionalSpecialArgs"
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
      allowed = allowedHostArgs ++ extraAllowed;
      bad = builtins.filter (k: !(builtins.elem k allowed) && builtins.substring 0 1 k != "_") (
        builtins.attrNames args
      );
    in
    if bad == [ ] then
      [ ]
    else
      [
        "${fnName}: unknown argument(s): ${builtins.concatStringsSep ", " bad} (typo?). Accepted: ${builtins.concatStringsSep ", " allowed}."
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
          "- `${name}`: the `additional*` arguments are the per-host halves of the layered pairs (modules/additionalModules, specialArgs/additionalSpecialArgs). Set the base half in `_defaults`, the additional half on the host entry."
        else
          "- `${name}`: not a builder argument (typo?). `_defaults` accepts: ${builtins.concatStringsSep ", " allowedDefaultArgs}.";
      badDefaults = map defaultComplaint (
        builtins.filter (k: !(builtins.elem k allowedDefaultArgs)) (builtins.attrNames defaults)
      );
      # every `_`-prefixed key is reserved, so none of them is ever a host
      hostEntries = builtins.removeAttrs hosts (
        builtins.filter (k: builtins.substring 0 1 k == "_") (builtins.attrNames hosts)
      );
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
      problems = badReserved ++ badDefaults ++ badHostKeys;
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
            "- `${name}`: the `additional*` arguments are the per-host halves of the layered pairs (modules/additionalModules, specialArgs/additionalSpecialArgs). Set the base half in `_defaults`, the additional half on the host entry."
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
      # mentions has the SAME VALUE as the default. Mere PRESENCE used to
      # disqualify it, so writing `inherit inputs system;` inside each host
      # entry -- the most natural thing to write -- silently gave every host
      # its own nixpkgs evaluation: 25 of them on a 25-host fleet, with no
      # signal. The comparison is tryEval-guarded because two structurally
      # equal attrsets holding functions cannot be compared at all, and
      # "cannot tell" must fall back to "own core", never to "share".
      sharesCore =
        entry:
        builtins.all (
          n:
          let
            probe = builtins.tryEval (entry.${n} == (split.defaults.${n} or null));
          in
          probe.success && probe.value
        ) (builtins.attrNames (builtins.intersectAttrs coreArgSet entry));
    in
    builtins.mapAttrs (hostname: entry: {
      args = split.defaults // entry // { inherit hostname; };
      core = if sharesCore entry then defaultsCore else null;
    }) split.hostEntries;

  # A plan entry's arguments, with the shared core attached when it has one.
  # `_core` is internal plumbing, never something a consumer writes.
  withCore = p: p.args // (if p.core != null then { _core = p.core; } else { });

  # A loginUsers typo is otherwise silent: the home flips to the
  # system-managed mechanism and everything still builds and boots. Only
  # checkable from a PLAN, where every host's registry is in view -- a name
  # that matches no user on one host is legal, a name no registry mentions
  # at all is a typo.
  planLoginUsers =
    fnName: plan:
    validateLoginUsers fnName (
      builtins.attrValues (
        builtins.mapAttrs (hostname: p: {
          inherit hostname;
          registry = p.args.userRegistry or { };
          loginUsers = p.args.loginUsers or [ ];
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
          rawRegistry = p.args.userRegistry or { };
          registry = if rawRegistry == null then { } else rawRegistry;
          # login-managed users that actually ship a home.nix on this host
          usersHome = loginUsersWithHome registry hostname (p.args.loginUsers or [ ]);
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
