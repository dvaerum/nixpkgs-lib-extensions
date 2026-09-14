# Report the last `hm-auto-upgrade` outcome as one line.
#
# Two callers, one format -- so the shell greeting and the on-demand
# command can never drift apart:
#
#   hm-auto-upgrade-status                 always prints (on demand)
#   hm-auto-upgrade-status --only-failures prints ONLY after a failure
#                                          (the interactive-shell hook)
#
# Exit status mirrors the last run: 0 when the last run succeeded or has
# never run, 1 when it failed -- so it composes in a script, not just for
# a human.

state_file="${1:-}"
only_failures=0

# `--only-failures` may come in either position; the state file is always
# passed by the generated hook/wrapper.
for arg in "$@"; do
  case "${arg}" in
    --only-failures) only_failures=1 ;;
    --*) ;;
    *) state_file="${arg}" ;;
  esac
done

if [ -z "${state_file}" ] || [ ! -r "${state_file}" ]; then
  [ "${only_failures}" = "1" ] && exit 0
  echo "home-manager auto-upgrade: has not run yet"
  exit 0
fi

status="$(sed -n 's/^status=//p' "${state_file}" | head -n1)"
exit_code="$(sed -n 's/^exit_code=//p' "${state_file}" | head -n1)"
target="$(sed -n 's/^target=//p' "${state_file}" | head -n1)"
timestamp="$(sed -n 's/^timestamp=//p' "${state_file}" | head -n1)"
# A free-form warning an `onResult` hook wrote back. The hook is the one
# thing that CANNOT report its own failures through its own channel --
# a broken notification setup has no way to announce that it is broken.
# This line does not depend on notifications working, so it is where
# that news belongs. Not a failure in itself: the run succeeded, only
# the reporting of it did not.
warn="$(sed -n 's/^warn=//p' "${state_file}" | head -n1)"

if [ "${status}" = "ok" ]; then
  # A warning is news even on a successful run -- that IS the case worth
  # surfacing, the upgrade worked and telling you about it did not.
  if [ -n "${warn}" ]; then
    echo "home-manager auto-upgrade: last succeeded ${timestamp} (${target}) -- WARNING: ${warn}"
    exit 0
  fi
  [ "${only_failures}" = "1" ] && exit 0
  echo "home-manager auto-upgrade: last succeeded ${timestamp} (${target})"
  exit 0
fi

echo "home-manager auto-upgrade: FAILED ${timestamp} (${target:-unresolved}, exit ${exit_code:-?})${warn:+ -- WARNING: ${warn}} -- journalctl --user -u hm-auto-upgrade" >&2
exit 1
