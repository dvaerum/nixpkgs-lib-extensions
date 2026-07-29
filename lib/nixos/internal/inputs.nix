# Input-convention introspection for the lib/nixos builders: how a flake
# input is recognized (home-manager, nixpkgs trees) and how its exports
# are mapped onto the auto-collection conventions. One of the four
# concern-files aggregated by ./shared.nix.
#
# Like the builder files it is a function of `extLib` — the fully
# assembled nixpkgs-lib-extensions lib (unused here, but every internal
# file keeps the same shape so their imports stay uniform).
extLib:
let
  # `builtins.warn` needs Nix >= 2.23; fall back to a trace with the same look.
  warn = builtins.warn or (msg: val: builtins.trace "evaluation warning: ${msg}" val);

  # The home-manager input, detected by capability (its `lib` exposes
  # `homeManagerConfiguration`) rather than by name, so it is found no matter
  # what the consuming flake calls the input. null if none is present.
  # A throwing `lib` in some unrelated input must not break detection
  # (tryEval), and ambiguity is surfaced: with several capable inputs the
  # alphabetically first wins WITH a warning -- pass the `homeManager`
  # builder argument to choose explicitly.
  detectHomeManager =
    inputs:
    let
      matches = builtins.filter (
        n:
        let
          v = inputs.${n};
          probe = builtins.tryEval (builtins.isAttrs v && (v.lib or { }) ? homeManagerConfiguration);
        in
        probe.success && probe.value
      ) (builtins.attrNames inputs);
    in
    if matches == [ ] then
      null
    else if builtins.length matches > 1 then
      warn ''
        nixpkgs-lib-extensions: several inputs look like home-manager (${builtins.concatStringsSep ", " matches}); using `${builtins.head matches}`. Pass `homeManager = inputs.<name>;` to the builder to choose explicitly.''
        inputs.${builtins.head matches}
    else
      inputs.${builtins.head matches};

  # From a flake's exported set (modules / overlays): the `default` export
  # is auto-loaded; without one, a set with exactly ONE entry is unambiguous
  # (sops-nix / plasma-manager style) and that entry is used. A set with
  # SEVERAL entries and no `default` is a catalog of opt-in entries
  # (nixos-hardware ships hundreds of mutually exclusive profiles, some of
  # them `throw` tombstones) -- importing them all is never right, so it
  # contributes nothing. Reference catalog entries explicitly (e.g.
  # `inputs.nixos-hardware.nixosModules.<profile>`) or add an
  # `inputSpecialCases` entry mapping the input onto the convention.
  # `what` names the source in the single-entry warning: that branch is
  # LOCK-FRAGILE -- upstream adding a second export (or a `default`)
  # silently changes a consumer's next flake update from "the one module"
  # to "nothing" (catalog treatment), so make the dependence visible.
  pickExported =
    what: s:
    if s ? default then
      [ s.default ]
    else if builtins.length (builtins.attrNames s) == 1 then
      warn ''
        nixpkgs-lib-extensions: auto-importing the sole export `${builtins.head (builtins.attrNames s)}` of ${what}. This changes if upstream adds exports -- pin it explicitly (or via inputSpecialCases) if you rely on it.''
        (builtins.attrValues s)
    else
      [ ];

  # Special cases for inputs that do not follow the generic output
  # conventions, keyed by the input's NAME in `inputs`. A case applies ONLY
  # to the input with that exact key and never affects the generic handling
  # of anything else. Each case maps the input onto the standard convention
  # attributes (nixosModules / homeManagerModules / homeModules / overlays /
  # extendLib); the generic collectors then treat it like any other input.
  # Add further special cases here.
  builtinInputSpecialCases = {
    # Currently empty. NUR used to be mapped here (`modules.nixos` /
    # `modules.homeManager`), but modern NUR's default modules do nothing
    # except inject its overlay via `nixpkgs.overlays` -- which the
    # generic collector already applies from NUR's `overlays.default`,
    # and which triggers home-manager's useGlobalPkgs warning in every
    # home. A case would look like:
    #   some-input = v: { nixosModules = v.odd.export.name or { }; };
    # Consumers extend this table via the `inputSpecialCases` builder
    # argument (which also serves as the per-input OPT-OUT for any
    # auto-collection channel: `some-input = _: { homeModules = { }; };`).
  };

  # The convention-shaped view of an input: its special case applied when
  # one exists for its name, the input itself otherwise.
  normalizeInput =
    cases: name: v:
    if builtins.isAttrs v && cases ? ${name} then v // cases.${name} v else v;

  # A real nixpkgs source tree (nixpkgs itself or a fork): exports package
  # sets AND can build NixOS systems. These are never module-imported
  # (their helper modules would break a system) and never lib-namespaced
  # (their lib IS the base).
  isNixpkgsTree = v: v ? legacyPackages && (v.lib or { }) ? nixosSystem;
in
{
  inherit
    warn
    detectHomeManager
    pickExported
    builtinInputSpecialCases
    normalizeInput
    isNixpkgsTree
    ;
}
