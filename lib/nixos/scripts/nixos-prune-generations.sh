# Generation retention for systemGarbageCollectModule.
#
# nixpkgs' `nix.gc` can express "delete older than 30 days" and nothing
# else. On a host that sat idle past the cutoff that deletes every
# generation but the current one, leaving no rollback target -- so the
# floor ("keep the newest N whatever their age") has to be applied by
# choosing the generations here rather than by a flag.
#
# This deletes things that cannot be recovered, so every branch below
# fails CLOSED: an output it cannot parse is a refusal, not an empty
# delete set and not a wipe.

profile=/nix/var/nix/profiles/system
keep_days=30
keep_generations=10
dry_run=0
collect=0
now=

usage() {
  cat >&2 <<'EOF'
usage: nixos-prune-generations [options]

Delete system-profile generations older than --keep-days, except the
newest --keep-generations of them and the currently-booted one.

  --profile PATH          default /nix/var/nix/profiles/system
  --keep-days N           age cutoff in days
  --keep-generations N     never delete this many newest, whatever their
                          age. 0 disables the floor (age alone governs).
  --collect               after pruning, run nix-collect-garbage to
                          reclaim the paths the deleted generations were
                          pinning. Without it the generations go but the
                          disk does not shrink.
  --dry-run               report what would be deleted, delete nothing
  --now EPOCH             fake clock, for tests
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile | --keep-days | --keep-generations | --now)
      if [ "$#" -lt 2 ]; then
        echo "nixos-prune-generations: $1 needs a value" >&2
        usage
        exit 64
      fi
      ;;
  esac
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --keep-days) keep_days="$2"; shift 2 ;;
    --keep-generations) keep_generations="$2"; shift 2 ;;
    --now) now="$2"; shift 2 ;;
    --collect) collect=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "nixos-prune-generations: unknown argument '$1'" >&2
      usage
      exit 64
      ;;
  esac
done

[ -n "$now" ] || now=$(date +%s)
log() { echo "nixos-prune-generations: $*"; }

cutoff=$((now - keep_days * 86400))

# `nix-env --list-generations` prints "  <id>   <YYYY-MM-DD HH:MM:SS>"
# with "   (current)" appended to one line. Parsed into "<id> <epoch>"
# pairs; a line that does not yield both is dropped, and the refusal
# below catches the case where that leaves nothing.
listing=$(nix-env -p "$profile" --list-generations 2>/dev/null || true)

current=""
parsed=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  id=$(printf '%s\n' "$line" | awk '{print $1}')
  case "$id" in
    "" | *[!0-9]*) continue ;;
  esac
  stamp=$(printf '%s\n' "$line" | awk '{print $2" "$3}')
  epoch=$(date -d "$stamp" +%s 2>/dev/null || true)
  case "$epoch" in
    "" | *[!0-9]*) continue ;;
  esac
  case "$line" in
    *"(current)"*) current="$id" ;;
  esac
  parsed="${parsed}${id} ${epoch}"$'\n'
done <<EOF
$listing
EOF

if [ -z "$parsed" ]; then
  # Deliberately an error. `nix-env` output changing shape must not look
  # like "nothing to prune" -- that would hide the breakage until the
  # generations piled up again, which is the very thing this exists for.
  log "no generations could be read from $profile -- refusing to delete anything"
  exit 1
fi

total=$(printf '%s' "$parsed" | grep -c .)

# The floor, by generation id: ids are monotonic, so the newest N are the
# N largest. Held as a space-padded string for substring matching.
protected=" "
if [ "$keep_generations" -gt 0 ]; then
  for id in $(printf '%s\n' "$parsed" | awk '{print $1}' | sort -rn | head -n "$keep_generations"); do
    protected="${protected}${id} "
  done
fi
# The running system is protected unconditionally: deleting it would
# remove the closure the machine is currently using.
[ -n "$current" ] && protected="${protected}${current} "

doomed=""
while read -r id epoch; do
  [ -n "$id" ] || continue
  case "$protected" in
    *" $id "*) continue ;;
  esac
  [ "$epoch" -lt "$cutoff" ] || continue
  doomed="${doomed:+$doomed }$id"
done <<EOF
$parsed
EOF

if [ -z "$doomed" ]; then
  log "$total generation(s), none both older than ${keep_days}d and outside the newest ${keep_generations}"
elif [ "$dry_run" -eq 1 ]; then
  count=$(printf '%s\n' "$doomed" | wc -w)
  log "$total generation(s); would delete $count older than ${keep_days}d (keeping the newest ${keep_generations} and the current one)"
  log "DRY-RUN: would delete generations: $doomed"
else
  count=$(printf '%s\n' "$doomed" | wc -w)
  log "$total generation(s); deleting $count older than ${keep_days}d (keeping the newest ${keep_generations} and the current one)"
  # shellcheck disable=SC2086 # deliberate word splitting: a list of ids
  nix-env -p "$profile" --delete-generations $doomed
fi

# Reclaiming is the point of pruning: deleting a generation only makes
# its closure collectable, and without this the generation count falls
# while the disk stays exactly as full. Run here, in this module's own
# unit -- NOT by switching on the host's `nix.gc`, which is a policy
# this module has no business writing.
#
# Unconditional on whether anything was pruned: other garbage accrues
# too, and a scheduled reclaim that silently skips is worse than no
# reclaim at all, because it looks like it is working.
if [ "$collect" -eq 1 ]; then
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN: would run nix-collect-garbage"
  else
    log "collecting unreferenced store paths"
    nix-collect-garbage
  fi
fi
