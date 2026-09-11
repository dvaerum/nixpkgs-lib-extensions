# Sandboxed behaviour test for scripts/nixos-prune-generations.sh. A stub
# `nix-env` serves a fixed generation list and records what the script
# asks to delete, so the retention policy is exercised without deleting
# anything real -- which matters more here than elsewhere in this repo:
# every other script's mistake is recoverable, and this one's is not.
{ pkgs }:
let
  # Emits the exact shape `nix-env --list-generations` prints, and
  # records deletions. GENS is "id:date" words.
  stub-collect = pkgs.writeShellScriptBin "nix-collect-garbage" ''
    echo "collect $*" >> "$RECORD"
  '';

  stub-nix-env = pkgs.writeShellScriptBin "nix-env" ''
    case "$*" in
      *--list-generations*)
        for g in ''${GENS:-}; do
          id="''${g%%:*}"; d="''${g#*:}"
          if [ "$id" = "''${CURRENT:-}" ]; then
            printf '  %s   %s   (current)\n' "$id" "$d"
          else
            printf '  %s   %s\n' "$id" "$d"
          fi
        done
        ;;
      *--delete-generations*)
        echo "delete $*" >> "$RECORD"
        ;;
    esac
  '';

  scripts = import ../../lib/nixos/internal/garbage-collect-script.nix {
    inherit pkgs;
    nixPackage = stub-nix-env;
    extraInputs = [
      stub-nix-env
      stub-collect
    ];
  };
in
pkgs.runCommand "nixos-prune-generations-script-test" { } ''
  set -x
  export RECORD=$TMPDIR/record
  : > "$RECORD"
  prune=${scripts.prune}/bin/nixos-prune-generations
  reset() { : > "$RECORD"; }

  # 2026-09-10 12:00:00 UTC
  NOW=1789041600
  base=(--profile /nix/var/nix/profiles/system --now "$NOW")

  # ── argument handling ──
  rc=0; "$prune" --bogus || rc=$?
  [ "$rc" -eq 64 ]
  rc=0; "$prune" --keep-days || rc=$?
  [ "$rc" -eq 64 ]

  # ── the floor is the whole point ──
  # Five generations, ALL far older than the cutoff. Age alone would
  # delete every one but the current; the floor must keep the newest 3.
  old="1:2026-01-01 2:2026-01-02 3:2026-01-03 4:2026-01-04 5:2026-01-05"
  reset
  GENS="$old" CURRENT=5 "$prune" "''${base[@]}" --keep-days 30 --keep-generations 3
  grep -q "delete" "$RECORD"
  # ids 1 and 2 go; 3, 4 and 5 are the newest three and stay
  grep -qE "delete .*--delete-generations( |.*[^0-9])1( |$)" "$RECORD"
  ! grep -qE -- "--delete-generations.* 4( |$)" "$RECORD"
  ! grep -qE -- "--delete-generations.* 5( |$)" "$RECORD"

  # ... with no floor, age alone governs and only `current` survives
  reset
  GENS="$old" CURRENT=5 "$prune" "''${base[@]}" --keep-days 30 --keep-generations 0
  for i in 1 2 3 4; do grep -qE -- "--delete-generations.*[ ]$i([ ]|$)" "$RECORD"; done
  ! grep -qE -- "--delete-generations.*[ ]5([ ]|$)" "$RECORD"

  # ── the current generation is NEVER deleted, whatever the numbers say ──
  # current is the OLDEST here, so both age and the floor would drop it
  reset
  GENS="$old" CURRENT=1 "$prune" "''${base[@]}" --keep-days 30 --keep-generations 0
  ! grep -qE -- "--delete-generations.*[ ]1([ ]|$)" "$RECORD"

  # ── nothing old enough: do nothing, and say so rather than deleting ──
  reset
  recent="10:2026-09-09 11:2026-09-10"
  GENS="$recent" CURRENT=11 "$prune" "''${base[@]}" --keep-days 30 --keep-generations 0
  [ ! -s "$RECORD" ]

  # ── an unparseable list is a REFUSAL, not a no-op and not a wipe ──
  # If `nix-env` output ever changes shape, deleting "everything that
  # did not parse" would be catastrophic and doing nothing silently
  # would hide it.
  reset
  rc=0; msg=$(GENS="" CURRENT= "$prune" "''${base[@]}" --keep-days 30 --keep-generations 3 2>&1) || rc=$?
  [ "$rc" -ne 0 ]
  echo "$msg" | grep -qi "no generations"
  [ ! -s "$RECORD" ]

  # ── reclaiming the space, which is the point of pruning ──────────
  # Deleting a generation only makes its closure collectable; without
  # this the disk never shrinks. Run in THIS module's own unit, never by
  # reaching into the host's `nix.gc`.
  reset
  GENS="$old" CURRENT=5 "$prune" "''${base[@]}" --keep-days 30 --keep-generations 3 --collect
  grep -q -- "--delete-generations" "$RECORD"
  grep -q "^collect" "$RECORD"
  # ... and the collection comes AFTER the prune, or it would not see
  # the paths the prune just freed
  [ "$(grep -n -- '--delete-generations' "$RECORD" | cut -d: -f1 | head -1)" \
    -lt "$(grep -n '^collect' "$RECORD" | cut -d: -f1 | head -1)" ]

  # it still collects when there was nothing to prune: other garbage
  # accrues too, and a scheduled reclaim that silently skips is worse
  # than useless
  reset
  GENS="$recent" CURRENT=11 "$prune" "''${base[@]}" --keep-days 30 --keep-generations 0 --collect
  ! grep -q -- "--delete-generations" "$RECORD"
  grep -q "^collect" "$RECORD"

  # without --collect nothing is reclaimed
  reset
  GENS="$old" CURRENT=5 "$prune" "''${base[@]}" --keep-days 30 --keep-generations 3
  ! grep -q "^collect" "$RECORD"

  # and --dry-run never collects either
  reset
  GENS="$old" CURRENT=5 "$prune" "''${base[@]}" --keep-days 30 --keep-generations 3 --collect --dry-run
  [ ! -s "$RECORD" ]

  # ── dry-run touches nothing ──
  reset
  res=$(GENS="$old" CURRENT=5 "$prune" "''${base[@]}" --keep-days 30 --keep-generations 3 --dry-run 2>&1)
  echo "$res" | grep -qi "DRY-RUN"
  [ ! -s "$RECORD" ]

  touch $out
''
