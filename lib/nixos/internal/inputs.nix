# Input-convention introspection for the lib/nixos builders: how a flake
# input is recognized (home-manager, nixpkgs trees), how its exports are
# mapped onto the auto-collection conventions, and how a consumer's
# `inputContributions` entry narrows or replaces them. One of the
# concern-files aggregated by ./shared.nix.
#
# Takes the loader's `{ lib, self, ... }`: nixpkgs' lib, and the fully
# assembled nixpkgs-lib-extensions lib.
{ lib, self, ... }:
let
  shownList = names: lib.concatStringsSep ", " names;

  # Above this many entries, the ambiguity throw below stops listing names --
  # nixos-hardware ships hundreds of mutually exclusive profiles, and a wall
  # of them helps nobody who has not asked for a specific one. Below it (a
  # nixos-raspberrypi, a sops-nix), printing the names is exactly what
  # resolves the ambiguity, so withholding them helps no one either.
  ambiguousListThreshold = 20;

  # An input's `lib`, or `{ }` if it has none OR if reading it throws.
  # `v.lib or { }` only covers a MISSING attribute: `?` and `or` force the
  # value to WHNF, so an input whose `lib` is a `throw` (a deprecation
  # tombstone, a broken flake) would take down every host that merely asks
  # "is this a nixpkgs tree?". Every site that inspects a foreign `lib`
  # goes through here.
  libOf =
    v:
    let
      probe = builtins.tryEval (if lib.isAttrs (v.lib or null) then v.lib else { });
    in
    if probe.success then probe.value else { };

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
      matches = lib.filter (
        n:
        let
          v = inputs.${n};
        in
        lib.isAttrs v && (libOf v) ? homeManagerConfiguration
      ) (lib.attrNames inputs);
    in
    if matches == [ ] then
      null
    else if lib.length matches > 1 then
      lib.warn
        "nixpkgs-lib-extensions: several inputs look like home-manager (${lib.concatStringsSep ", " matches}); using `${lib.head matches}`. Pass `homeManager = inputs.<name>;` to choose explicitly -- `homeManager` is a builder argument like `system` or `patches`, so it goes wherever those do: a direct `mkNixosSystem`/`mkHomeConfiguration` call, or in a hosts attrset's `_defaults` (every host), a `_groups` entry, or one host."
        inputs.${lib.head matches}
    else
      inputs.${lib.head matches};

  # ── the auto-collection channels ──
  #
  # Every channel an input can contribute to automatically. `inputContributions`
  # is keyed by channel name, so this list doubles as the allowlist for its
  # keys. Entry-set channels hold a SET of entries, so a selection can name
  # the ones to take; single-value channels hold one value, which a selection
  # can only switch on or off.
  #
  # Each entry-set channel maps to HOW its exports are located on an input.
  # collectFromInputs below derives its collectors from this very table, so
  # a channel added here gets collected by construction -- the accepted-keys
  # list cannot drift away from the code that acts on it.
  entrySetChannels = {
    nixosModules = v: v.nixosModules or { };
    homeModules = v: v.homeModules or { };
    overlays = v: v.overlays or { };
  };
  # These hold ONE value, so a selection can only switch them on or off, and
  # each is consumed at its own site inside the lib fixed point (context.nix)
  # rather than through a generic collector.
  singleValueChannels = [
    "libOverlays"
    "lib"
  ];
  channelNames = lib.attrNames entrySetChannels ++ singleValueChannels;

  # The ambiguity throw's message, factored out to a plain (non-throwing)
  # function so a test can call it directly and pin the text -- tryEval
  # discards throw messages, like the other harness-error assertions (see
  # probeCoreOverrideMessage in checks/builders/default.nix for the same
  # pattern). `names` is `lib.attrNames` of the exported set; the exported
  # names themselves are listed IF there are few enough to be useful (at or
  # below `ambiguousListThreshold`): nixos-raspberrypi's 8 overlays are
  # exactly what you need to pick one, but nixos-hardware's hundreds of
  # mutually exclusive profiles (some of them `throw` tombstones) would be a
  # wall of text that helps nobody who has not asked for a specific one --
  # over the threshold, the message points at the input's own flake.nix
  # instead. Below the threshold this doubles as the "what's available"
  # answer resolveEntrySet gives when you DO name an entry and it does not
  # exist.
  ambiguousExportMessage =
    name: channel: names:
    let
      count = lib.length names;
    in
    ''
      nixpkgs-lib-extensions: input `${name}` exports ${toString count} ${channel} entries and no `default` -- auto-import will not guess. Select what you want via the builder's inputContributions argument:
        inputContributions."${name}".${channel} = [ "<entry>" ]; # these entries, in this order
        inputContributions."${name}".${channel} = "*";           # all of them
        inputContributions."${name}".${channel} = null;          # none -- select per host instead
      ${
        if count <= ambiguousListThreshold then
          "Exported ${channel}: ${shownList names}."
        else
          "Too many to list (${toString count}) -- inspect the input's own flake.nix instead."
      }'';

  # From a flake's exported set for one channel, with NO selection given:
  # the `default` export is auto-loaded; without one, a set with exactly ONE
  # entry is unambiguous (sops-nix / plasma-manager style) and that entry is
  # used. A set with SEVERAL entries and no `default` is ambiguous --
  # importing them all is never right and silently skipping would hide
  # functionality, so it THROWS (see ambiguousExportMessage above for what
  # the message says and why). `name` is the input's key in `inputs`,
  # `channel` the convention attribute; both only render the message.
  # LAZINESS: the decision looks at lib.attrNames / length ONLY -- export
  # VALUES are never forced here, because real catalogs contain `throw`
  # tombstones for removed entries.
  pickExported =
    name: channel: s:
    let
      names = lib.attrNames s;
    in
    if s ? default then
      [ s.default ]
    else if lib.length names == 1 then
      lib.attrValues s
    else if names == [ ] then
      [ ]
    else
      throw (ambiguousExportMessage name channel names);

  # A consumer's `inputContributions.<input>` entry comes in three forms:
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
          selections = lib.listToAttrs (
            map (c: {
              name = c;
              value = null;
            }) channelNames
          );
        }
      # builtins.isFunction on purpose (NOT lib.isFunction, which also
      # accepts `__functor` attrsets): an attrset case must fall through to
      # the selection branch below, where its keys are validated
      else if builtins.isFunction v then
        {
          remap = v;
          selections = { };
        }
      else if lib.isAttrs v then
        let
          bad = lib.filter (k: !(lib.elem k channelNames)) (lib.attrNames v);
        in
        if bad == [ ] then
          {
            remap = null;
            selections = v;
          }
        else
          throw ''nixpkgs-lib-extensions: inputContributions."${name}": unknown channel(s) ${shownList bad} (typo?). Valid channels: ${shownList channelNames}.''
      else
        throw ''nixpkgs-lib-extensions: inputContributions."${name}" must be `null` (contribute nothing), a function (map the input onto the convention attributes), or an attrset of per-channel selections -- got a value of type `${builtins.typeOf v}`.'';

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
        available = lib.attrNames exported;
      in
      if selection == null || selection == [ ] then
        [ ]
      else if selection == "*" then
        lib.attrValues exported
      else if lib.isList selection && lib.all lib.isString selection then
        let
          missing = lib.filter (n: !(lib.elem n available)) selection;
        in
        if missing == [ ] then
          map (n: exported.${n}) selection
        else
          throw ''nixpkgs-lib-extensions: inputContributions."${name}".${channel} selects ${shownList missing}, which input `${name}` does not export. Exported ${channel}: ${
            if available == [ ] then "(none)" else shownList available
          }.''
      else
        # also the landing place for a list holding something other than
        # entry NAMES -- without the isString guard above, `[ 1 ]` would die
        # in string interpolation with an uncatchable coercion error instead
        # of this message.
        throw
          ''nixpkgs-lib-extensions: inputContributions."${name}".${channel} must be a list of entry names (strings), `"*"` (all), or `null` / `[ ]` (none) -- got ${
            if lib.isList selection then
              "a list holding a non-string"
            else
              "a value of type `${builtins.typeOf selection}`"
          }.'';

  # Whether a SINGLE-VALUE channel (`libOverlays`, `lib`) contributes. One
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
        throw ''nixpkgs-lib-extensions: inputContributions."${name}".${channel} holds a single value, not a set of entries: only `null` / `[ ]` (off) and `"*"` (on) are accepted -- got a value of type `${builtins.typeOf selection}`.'';

  # A case keyed by an input that does not exist is a silent no-op -- and the
  # error it was written to fix comes back unexplained. Same defect class as
  # an unknown channel key, caught the same way.
  validateCases =
    inputs: cases:
    let
      bad = lib.filter (n: !(inputs ? ${n})) (lib.attrNames cases);
    in
    if bad == [ ] then
      cases
    else
      throw "nixpkgs-lib-extensions: inputContributions names input(s) ${shownList bad}, which are not in `inputs` (typo?). Known inputs: ${shownList (lib.attrNames inputs)}.";

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
    # Consumers extend this table via the `inputContributions` builder
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
      # The function form was the ONE unvalidated shape: a typo in a
      # returned channel name (`nixosModuls`) contributed nothing, silently,
      # while the identical typo in the attrset form throws by name -- and
      # the whole point of the function form is exports under nonstandard
      # paths, so silence is the worst possible answer. Returning the
      # modules directly instead of wrapping them gave a bare "expected a
      # set but found a list" naming neither the input nor the argument.
      remapped =
        let
          r = case.remap v;
        in
        if !(lib.isAttrs r) then
          throw ''nixpkgs-lib-extensions: inputContributions."${name}" is a function, so it must RETURN an attrset mapping this input onto the convention attributes (e.g. `v: { nixosModules = v.modules.nixos; }`) -- it returned a value of type `${builtins.typeOf r}`.''
        else
          let
            bad = lib.filter (k: !(lib.elem k channelNames)) (lib.attrNames r);
          in
          if bad == [ ] then
            r
          else
            throw ''nixpkgs-lib-extensions: inputContributions."${name}" returned unknown channel(s) ${shownList bad} (typo?). Valid channels: ${shownList channelNames}.'';
    in
    if lib.isAttrs v && case.remap != null then v // remapped else v;

  # Deduplicate the PATH elements of a collected module/overlay list,
  # keeping every non-path element as-is (order preserved). A blanket
  # `lib.unique` would deep-compare attrset modules, which can THROW when
  # two distinct modules carry functions at the same attribute path; only
  # paths have a cheap, reliable identity, so only they are deduplicated
  # (the module system tolerates the rare duplicated attrset module fine).
  uniquePaths =
    list:
    (lib.foldl'
      (
        acc: x:
        if !(lib.isPath x) then
          acc // { out = acc.out ++ [ x ]; }
        else if lib.elem x acc.seen then
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

  # Everything an input contributes automatically, resolved in one place:
  # the consumer's cases (validated against the real input names), the
  # function-form remap, the per-channel selections, the eager validation
  # of every selection written, and the collectors for each entry-set
  # channel. `skipFor` carries the per-channel built-in skips, which need
  # the caller's home-manager identity and so cannot live here.
  collectFromInputs =
    {
      inputs,
      inputContributions,
      baseLib,
      skipFor ? { },
    }:
    let
      cases = builtinInputSpecialCases // (validateCases inputs inputContributions);
      conventionInputs = baseLib.mapAttrs (normalizeInput cases) inputs;
      caseOf = classifyCase cases;

      # The built-in `skip` rules are consulted ONLY when the consumer said
      # nothing about this input -- they stop the builder from GUESSING, and
      # ANY explicit case is the opposite of a guess. That includes the
      # FUNCTION form: remapping an input's exports onto the conventions is a
      # statement that you want them, so skipping afterwards would apply the
      # remap and silently discard the result.
      collectChannel =
        channel: locate:
        let
          skip = skipFor.${channel} or (_: _: false);
        in
        uniquePaths (
          baseLib.concatLists (
            baseLib.mapAttrsToList (
              name: v:
              let
                case = caseOf name;
                explicit = case.selections ? ${channel} || case.remap != null;
              in
              if !(baseLib.isAttrs v) || (!explicit && skip name v) then
                [ ]
              else
                resolveEntrySet name channel (locate v) case
            ) conventionInputs
          )
        );

      # Entry-name validation must not depend on whether the CALLER happens
      # to collect the channel: a `homeModules` typo on a host with no
      # system-managed homes would otherwise never be forced, while the docs
      # promise every typo fails loudly. Scoped to the inputs the consumer
      # named, so nothing else is probed. `length` forces the list's shape,
      # never the entries, so catalog tombstones stay unforced.
      selectionsChecked =
        let
          probe =
            name: _:
            let
              case = caseOf name;
              v = conventionInputs.${name};
            in
            baseLib.optionals (baseLib.isAttrs v) (
              baseLib.mapAttrsToList (
                channel: locate: baseLib.length (resolveEntrySet name channel (locate v) case)
              ) (baseLib.intersectAttrs case.selections entrySetChannels)
            );
        in
        baseLib.deepSeq (baseLib.concatLists (baseLib.mapAttrsToList probe inputContributions)) null;
    in
    {
      inherit conventionInputs caseOf selectionsChecked;
      # one collector per entry-set channel, derived from that same table
      collected = baseLib.mapAttrs collectChannel entrySetChannels;
    };

  # A real nixpkgs source tree (nixpkgs itself or a fork): exports package
  # sets AND can build NixOS systems. These are never module-imported
  # (their helper modules would break a system) and never lib-namespaced
  # (their lib IS the base).
  isNixpkgsTree = v: v ? legacyPackages && (libOf v) ? nixosSystem;
in
{
  # Exported = consumed elsewhere (context.nix, hosts-args.nix and
  # shared.nix). The channel tables, the case machinery (classifyCase,
  # resolveEntrySet, ...) and pickExported stay private: implementation
  # detail of the functions below, and re-exporting them would read as
  # public surface. ambiguousExportMessage is the one exception: it is
  # exposed ONLY so a test can pin the ambiguity throw's text (tryEval
  # discards throw messages) -- shared.nix, its sole consumer, is itself
  # private, so this never reaches the published lib.
  inherit
    detectHomeManager
    libOf
    channelEnabled
    collectFromInputs
    isNixpkgsTree
    ambiguousExportMessage
    ;
}
