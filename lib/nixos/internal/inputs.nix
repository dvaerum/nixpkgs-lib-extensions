# Input-convention introspection for the lib/nixos builders: how a flake
# input is recognized (home-manager, nixpkgs trees), how its exports are
# mapped onto the auto-collection conventions, and how a consumer's
# `inputSpecialCases` entry narrows or replaces them. One of the four
# concern-files aggregated by ./shared.nix.
#
# Like the builder files it is a function of `extLib` — the fully
# assembled nixpkgs-lib-extensions lib (unused here, but every internal
# file keeps the same shape so their imports stay uniform).
extLib:
let
  shownList = names: builtins.concatStringsSep ", " names;

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
      builtins.warn
        "nixpkgs-lib-extensions: several inputs look like home-manager (${builtins.concatStringsSep ", " matches}); using `${builtins.head matches}`. Pass `homeManager = inputs.<name>;` to the builder to choose explicitly."
        inputs.${builtins.head matches}
    else
      inputs.${builtins.head matches};

  # ── the auto-collection channels ──
  #
  # Every channel an input can contribute to automatically. `inputSpecialCases`
  # is keyed by channel name, so this list doubles as the allowlist for its
  # keys. Entry-set channels hold a SET of entries, so a selection can name
  # the ones to take; single-value channels hold one value, which a selection
  # can only switch on or off.
  #
  # Each entry-set channel maps to HOW its exports are located on an input.
  # internal/context.nix derives its collectors from this very table, so a
  # channel added here gets collected by construction -- the accepted-keys
  # list cannot drift away from the code that acts on it.
  entrySetChannels = {
    nixosModules = v: v.nixosModules or { };
    # the older `homeManagerModules` name is read ONLY when `homeModules` is
    # absent -- flakes that deprecated it (plasma-manager) warn on access
    homeModules = v: v.homeModules or v.homeManagerModules or { };
    overlays = v: v.overlays or { };
  };
  # These hold ONE value, so a selection can only switch them on or off, and
  # each is consumed at its own site inside the lib fixed point (context.nix)
  # rather than through a generic collector.
  singleValueChannels = [
    "extendLib"
    "lib"
  ];
  channelNames = builtins.attrNames entrySetChannels ++ singleValueChannels;

  # From a flake's exported set for one channel, with NO selection given:
  # the `default` export is auto-loaded; without one, a set with exactly ONE
  # entry is unambiguous (sops-nix / plasma-manager style) and that entry is
  # used. A set with SEVERAL entries and no `default` is ambiguous
  # (nixos-hardware ships hundreds of mutually exclusive profiles, some of
  # them `throw` tombstones) -- importing them all is never right and
  # silently skipping would hide functionality, so it THROWS with the three
  # selections that resolve it. It does NOT list the exported names: a real
  # catalog has hundreds, and a wall of them helps nobody who has not asked
  # for a specific one. That listing belongs to the error you get when you
  # DO name an entry and it does not exist (see resolveEntrySet). `name` is
  # the input's key in `inputs`, `channel` the convention attribute; both
  # only render the message. LAZINESS: the decision looks at
  # builtins.attrNames / length ONLY -- export VALUES are never forced here,
  # because real catalogs contain `throw` tombstones for removed entries.
  pickExported =
    name: channel: s:
    let
      names = builtins.attrNames s;
    in
    if s ? default then
      [ s.default ]
    else if builtins.length names == 1 then
      builtins.attrValues s
    else if names == [ ] then
      [ ]
    else
      throw ''
        nixpkgs-lib-extensions: input `${name}` exports ${toString (builtins.length names)} ${channel} entries and no `default` -- auto-import will not guess. Select what you want via the builder's inputSpecialCases argument:
          inputSpecialCases."${name}".${channel} = [ "<entry>" ]; # these entries, in this order
          inputSpecialCases."${name}".${channel} = "*";           # all of them
          inputSpecialCases."${name}".${channel} = null;          # none -- select per host instead'';

  # A consumer's `inputSpecialCases.<input>` entry comes in three forms:
  #
  #   null                  the input contributes NOTHING, to any channel
  #   function              escape hatch: maps the input onto the convention
  #                         attributes, for exports living under nonstandard
  #                         paths (`v: { nixosModules = v.modules.nixos; }`)
  #   { <channel> = ...; }  per-channel SELECTION (see resolveEntrySet and
  #                         channelEnabled)
  #
  # Classified into `{ remap, selections }` so the collectors ask one
  # question per channel. Unknown channel keys THROW: otherwise a typo'd key
  # silently means "no selection", and the ambiguity throw the selection was
  # written to resolve comes back looking like a broken feature.
  classifyCase =
    cases: name:
    if !(cases ? ${name}) then
      {
        remap = null;
        selections = { };
      }
    else
      let
        v = cases.${name};
      in
      if v == null then
        {
          remap = null;
          # every channel off
          selections = builtins.listToAttrs (
            map (c: {
              name = c;
              value = null;
            }) channelNames
          );
        }
      else if builtins.isFunction v then
        {
          remap = v;
          selections = { };
        }
      else if builtins.isAttrs v then
        let
          bad = builtins.filter (k: !(builtins.elem k channelNames)) (builtins.attrNames v);
        in
        if bad == [ ] then
          {
            remap = null;
            selections = v;
          }
        else
          throw ''nixpkgs-lib-extensions: inputSpecialCases."${name}": unknown channel(s) ${shownList bad} (typo?). Valid channels: ${shownList channelNames}.''
      else
        throw ''nixpkgs-lib-extensions: inputSpecialCases."${name}" must be `null` (contribute nothing), a function (map the input onto the convention attributes), or an attrset of per-channel selections -- got a value of type `${builtins.typeOf v}`.'';

  # What an input contributes to one ENTRY-SET channel:
  #
  #   no selection   the pickExported rule (default / sole entry / throw)
  #   null or [ ]    nothing
  #   [ "a" "b" ]    exactly those entries, in the order given
  #   "*"            every entry (attrValues order, i.e. alphabetical)
  #
  # A selection naming an entry the input does not export THROWS, listing
  # what it does export -- naming entries only beats hand-plumbing them if a
  # typo says so. LAZINESS holds: choosing reads attrNames only, so a
  # catalog's unselected entries (possibly `throw` tombstones) are never
  # forced.
  resolveEntrySet =
    name: channel: exported: case:
    if !(case.selections ? ${channel}) then
      pickExported name channel exported
    else
      let
        selection = case.selections.${channel};
        available = builtins.attrNames exported;
      in
      if selection == null || selection == [ ] then
        [ ]
      else if selection == "*" then
        builtins.attrValues exported
      else if builtins.isList selection && builtins.all builtins.isString selection then
        let
          missing = builtins.filter (n: !(builtins.elem n available)) selection;
        in
        if missing == [ ] then
          map (n: exported.${n}) selection
        else
          throw ''nixpkgs-lib-extensions: inputSpecialCases."${name}".${channel} selects ${shownList missing}, which input `${name}` does not export. Exported ${channel}: ${
            if available == [ ] then "(none)" else shownList available
          }.''
      else
        # also the landing place for a list holding something other than
        # entry NAMES -- without the isString guard above, `[ 1 ]` would die
        # in string interpolation with an uncatchable coercion error instead
        # of this message.
        throw
          ''nixpkgs-lib-extensions: inputSpecialCases."${name}".${channel} must be a list of entry names (strings), `"*"` (all), or `null` / `[ ]` (none) -- got ${
            if builtins.isList selection then
              "a list holding a non-string"
            else
              "a value of type `${builtins.typeOf selection}`"
          }.'';

  # Whether a SINGLE-VALUE channel (`extendLib`, `lib`) contributes. One
  # value holds nothing to choose between, so a selection can only switch the
  # channel off.
  channelEnabled =
    name: channel: case:
    if !(case.selections ? ${channel}) then
      true
    else
      let
        selection = case.selections.${channel};
      in
      if selection == null || selection == [ ] then
        false
      else if selection == "*" then
        true
      else
        throw ''nixpkgs-lib-extensions: inputSpecialCases."${name}".${channel} holds a single value, not a set of entries: only `null` / `[ ]` (off) and `"*"` (on) are accepted -- got a value of type `${builtins.typeOf selection}`.'';

  # A case keyed by an input that does not exist is a silent no-op -- and the
  # error it was written to fix comes back unexplained. Same defect class as
  # an unknown channel key, caught the same way.
  validateCases =
    inputs: cases:
    let
      bad = builtins.filter (n: !(inputs ? ${n})) (builtins.attrNames cases);
    in
    if bad == [ ] then
      cases
    else
      throw "nixpkgs-lib-extensions: inputSpecialCases names input(s) ${shownList bad}, which are not in `inputs` (typo?). Known inputs: ${shownList (builtins.attrNames inputs)}.";

  # Special cases for inputs that do not follow the generic output
  # conventions, keyed by the input's NAME in `inputs`. A case applies ONLY
  # to the input with that exact key and never affects the generic handling
  # of anything else. Add further special cases here.
  builtinInputSpecialCases = {
    # Currently empty. NUR used to be mapped here (`modules.nixos` /
    # `modules.homeManager`), but modern NUR's default modules do nothing
    # except inject its overlay via `nixpkgs.overlays` -- which the
    # generic collector already applies from NUR's `overlays.default`,
    # and which triggers home-manager's useGlobalPkgs warning in every
    # home. A case would look like:
    #   some-input = v: { nixosModules = v.odd.export.name or { }; };
    # Consumers extend this table via the `inputSpecialCases` builder
    # argument, which is also where a channel is narrowed to named entries
    # or switched off entirely.
  };

  # The convention-shaped view of an input: the FUNCTION form of its case
  # applied when one exists (the selection forms are handled per channel by
  # resolveEntrySet / channelEnabled, not by rewriting the input).
  normalizeInput =
    cases: name: v:
    let
      case = classifyCase cases name;
    in
    if builtins.isAttrs v && case.remap != null then v // case.remap v else v;

  # A real nixpkgs source tree (nixpkgs itself or a fork): exports package
  # sets AND can build NixOS systems. These are never module-imported
  # (their helper modules would break a system) and never lib-namespaced
  # (their lib IS the base).
  isNixpkgsTree = v: v ? legacyPackages && (v.lib or { }) ? nixosSystem;
in
{
  # Exported = consumed elsewhere. The channel lists, pickExported and the
  # rest stay private: they are implementation detail of the functions
  # below, and re-exporting them would read as public surface.
  inherit
    detectHomeManager
    entrySetChannels
    classifyCase
    resolveEntrySet
    channelEnabled
    validateCases
    builtinInputSpecialCases
    normalizeInput
    isNixpkgsTree
    ;
}
