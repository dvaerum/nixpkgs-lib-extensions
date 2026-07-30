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

  # Direct-call argument validation for the singular builders: the same
  # rigor splitHostsArgs applies to hosts attrsets, at the other door --
  # otherwise the `...` patterns silently swallow typos and stale names.
  # `extraAllowed` covers builder-specific keys (e.g. `username`);
  # _-prefixed keys are internal plumbing and always pass.
  validateBuilderArgs =
    fnName: extraAllowed: args:
    let
      allowed = allowedHostArgs ++ extraAllowed;
      bad = builtins.filter (k: !(builtins.elem k allowed) && builtins.substring 0 1 k != "_") (
        builtins.attrNames args
      );
    in
    if bad == [ ] then
      args
    else
      throw ''
        ${fnName}: unknown argument(s): ${builtins.concatStringsSep ", " bad} (typo?). Accepted: ${builtins.concatStringsSep ", " allowed}.
      '';

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
in
{
  inherit
    allowedDefaultArgs
    allowedHostArgs
    validateBuilderArgs
    splitHostsArgs
    ;
}
