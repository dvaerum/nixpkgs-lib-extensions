# The assertion reporter shared by every eval-time check.
#
# It replaces `failed = attrNames (filterAttrs (_: ok: ok != true) assertions)`,
# which had two problems:
#
#   - `filterAttrs` forces every value in ONE expression, so a single
#     assertion that THROWS (easy: most read deep into a built system)
#     aborted the whole check with that throw's message and no assertion
#     name attached. All ~140 became one opaque failure.
#   - a failing assertion yielded only its name. Several are 5- and 6-way
#     `&&` chains, so you learned "one of six things is wrong".
#
# An assertion value may be:
#   true          passed
#   false         failed, reported by name
#   a string      failed, reported by name WITH that string as the reason
#   (a throw)     failed, reported by name as "threw" -- never fatal
#
# The result also carries `passthru.assertions`, so a single assertion can
# be inspected without editing the check:
#   nix eval .#checks.x86_64-linux.builders.passthru.assertions --json
{ pkgs }:
let
  lib = pkgs.lib;

  # A value that neither passes nor explains itself is reported as a plain
  # failure; `tryEval` keeps a throwing assertion from taking the rest with
  # it. Only WHNF is forced -- an assertion returning a deep structure is
  # the check author's business, not ours.
  verdict =
    value:
    let
      probe = builtins.tryEval value;
    in
    if !probe.success then
      "threw while evaluating"
    else if probe.value == true then
      null
    else if builtins.isString probe.value then
      probe.value
    else
      "expected true, got ${builtins.toJSON probe.value}";
in
{
  # `eq`/`allOf` turn a `&&` chain into named sub-conditions at no cost:
  #   defaults-applied = allOf {
  #     module = groups ? from-defaults;
  #     tags = eq specialArgs.tags [ "default-tag" ];
  #   };
  eq =
    actual: expected:
    if actual == expected then
      true
    else
      "expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  allOf =
    conditions:
    let
      failures = lib.filterAttrs (_: v: verdict v != null) conditions;
      names = lib.attrNames failures;
    in
    if names == [ ] then
      true
    else
      lib.concatMapStringsSep "; " (n: "${n}: ${verdict failures.${n}}") names;

  # name: the derivation name; assertions: the attrset under test.
  run =
    name: assertions:
    let
      failures = lib.filterAttrs (_: reason: reason != null) (lib.mapAttrs (_: verdict) assertions);
      names = lib.attrNames failures;
      report = lib.concatMapStringsSep "\n" (n: "  - ${n}: ${failures.${n}}") names;
    in
    if names == [ ] then
      (pkgs.runCommand name { } "touch $out").overrideAttrs (old: {
        passthru = (old.passthru or { }) // {
          inherit assertions;
        };
      })
    else
      throw ''
        ${name}: ${toString (builtins.length names)} of ${toString (builtins.length (lib.attrNames assertions))} assertions failed:
        ${report}
      '';
}
