# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ lib, ... }:
{
  /**
    Run a shell command detached from the caller, in a fresh
    `systemd-run --user` transient unit, following its journal for
    interactive output and propagating success or failure (exit 0/1) from the unit's `Result` --
    an unreadable/empty `Result` is treated as success. Built for
    commands whose own effects can restart the unit the CALLER is running
    in -- `home-manager switch` is the motivating case (see
    `interceptingWrapper`): its activation restarts every user unit whose
    store path changed, which can include the very unit the calling
    shell's cgroup lives in (a tmux-server.service, a timer unit's own
    ExecStart, ...). Stopping that unit TERMs the in-flight activation --
    stops run, starts never do. Running detached breaks that link: the
    transient unit is never part of any restart set, so it completes even
    if whatever launched it is killed mid-run; only the interactive
    journal tail dies with it.

    Returns a shell script FRAGMENT (a string), not a derivation -- splice
    it into a wrapper script (`interceptingWrapper` does this) or straight
    into a systemd unit's own `ExecStart` (a timer-triggered upgrade
    service is exactly this: wrapping its own `home-manager switch` call
    the same way protects it from the identical self-restart risk).
    `command`, like `interceptingWrapper`'s `shouldDetach`, is raw shell
    syntax spliced in verbatim (e.g. `"$real" "$@"`) -- not a Nix-modeled
    argv list.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    # as a systemd service's ExecStart:
    script = extLib.systemd.detachedRun pkgs {
      label = "hm-upgrade";
      command = "${pkgs.home-manager}/bin/home-manager switch";
      extraProperties = [ "RuntimeMaxSec=7200" ];
    };
    ```

    # Type

    ```
    detachedRun :: pkgs -> Attribute -> String
    ```

    # Arguments

    pkgs
    : The package set `systemd-run`/`journalctl`/`systemctl` are taken from.

    label
    : Names the transient unit (prefixed, followed by a timestamp and PID
    : for uniqueness) AND the failure message verbatim -- keep it a valid
    : systemd unit-name component (letters, digits, `:_.-`; no spaces). A
    : human-readable label like "home-manager switch" reads better in the
    : failure text but is not a legal unit name; a slug like "hm-switch"
    : is both at once, at the cost of a plainer message.

    command
    : Raw shell syntax for the command to run detached, e.g. `"$real" "$@"`
    : or a fixed invocation. Spliced verbatim after `systemd-run`'s own
    : flags.

    extraEnv
    : Names of additional environment variables to forward into the
    : transient unit, read from the CALLER's environment at runtime (a
    : shell loop with indirect expansion, since their VALUES are not
    : known until the script actually runs). `PATH` is always forwarded
    : and does not need to be listed. Default `[ ]`.

    extraProperties
    : Additional `systemd-run --property=` values, verbatim `"NAME=VALUE"`
    : strings -- e.g. `[ "RuntimeMaxSec=7200" ]`. Unlike `extraEnv` these
    : are static configuration, known at Nix eval time, so they are
    : spliced directly rather than read from the runtime environment.
    : Default `[ ]`.
  */
  detachedRun =
    pkgs:
    {
      label,
      command,
      extraEnv ? [ ],
      extraProperties ? [ ],
    }:
    if !(lib.isString label) then
      throw "detachedRun: `label` must be a string, but is a value of type `${builtins.typeOf label}`"
    else if builtins.match "[A-Za-z0-9:_.-]+" label == null then
      throw "detachedRun: `label` must be a valid systemd unit-name component (letters, digits, `:_.-`, no spaces) -- got `${label}`. It becomes part of the transient unit's name."
    else
      ''
        unit="${label}-$(date +%s)-$$"
        declare -a extra_setenv=()
        for name in ${lib.concatStringsSep " " extraEnv}; do
          extra_setenv+=(--setenv="$name=''${!name}")
        done
        ${pkgs.systemd}/bin/systemd-run --user --collect --quiet \
          --unit="$unit" --same-dir \
          --setenv=PATH="$PATH" \
          "''${extra_setenv[@]}" \
          ${lib.concatMapStringsSep " " (p: "--property=" + lib.escapeShellArg p) extraProperties} \
          ${command}

        # Follow output; survives being killed (the unit keeps running).
        ${pkgs.systemd}/bin/journalctl --user -u "$unit" -f --no-pager -o cat &
        tail_pid=$!
        while ${pkgs.systemd}/bin/systemctl --user --quiet is-active "$unit"; do
          sleep 1
        done
        sleep 1  # let the last journal lines flush through the tail
        kill "$tail_pid" 2>/dev/null
        result=$(${pkgs.systemd}/bin/systemctl --user show "$unit" \
          --property=Result --value 2>/dev/null)
        if [ "$result" = "success" ] || [ -z "$result" ]; then
          exit 0
        fi
        echo "${label} failed (unit $unit, result: $result)" >&2
        exit 1
      '';
}
