# PRIVATE, consumed directly by declare-zfs-root-disk.nix and
# declare-zfs-data-disk.nix -- the two functions share ONE hardware-identity
# key scheme (deliberately unsalted -- see each caller's own THREAT MODEL
# doc comment for why: this is meant to make a SEPARATED disk unreadable
# while still auto-unlocking on its original hardware, not to keep two
# pools on the SAME machine from sharing key material).
{ lib, pkgs }:
let
  # dmidecode's own known placeholder shapes (BIOS fields left
  # unset, or a widely-observed Dell service-tag placeholder GUID).
  dmidecodeJunkPatterns = [
    "\"Not Settable\""
    "\"Not Present\""
    "00000000-0000-0000-0000-000000000000"
    "03000200-0400-0500*"
  ];

  # `/proc/cpuinfo`'s `Serial` field, as set by the Raspberry Pi
  # VideoCore firmware: all-zeros specifically on a failed "get board
  # serial" mailbox call, not a missing line (the universal `""` check
  # covers that case instead).
  cpuinfoSerialJunkPatterns = [ "0000000000000000" ];

  # The encryption key file is written in multiple places (pool
  # creation, and at boot by whichever unlock mechanism the caller
  # uses) -- ONE definition producing deterministic bytes, so those
  # writers cannot drift (`cat <<<` appends a trailing newline where
  # `echo -n` does not); the callers' own key-file checks pin that
  # invariant. It expects `KEY` to be set by the caller.
  #
  # `junkPatterns`: extra shell `case` alternatives (besides the
  # universal, source-independent bare `""`) naming values THIS
  # particular key source is known to emit on failure -- a UUID-shaped
  # placeholder only means something for dmidecode's output, a
  # hex-shaped one only for `/proc/cpuinfo`'s `Serial`, so each source
  # supplies its own list (see `keySourceFor` below) rather than this
  # shared writer hardcoding one source's shapes.
  #
  # POSIX sh only (no `[[`, no `$'...'`): a script-initrd caller runs
  # this under busybox ash (BusyBox's minimal Almquist-shell clone --
  # the only shell present in that stripped-down environment, and it
  # rejects bash-only syntax), and one snippet serves every context.
  writeKeyFile = keyFilePath: junkPatterns: ''
    SECRET_FOLDER_PATH="${builtins.dirOf keyFilePath}"
    KEY_FILE_PATH="${keyFilePath}"

    # REFUSE to derive a key from junk. Empty output or one of the
    # known placeholder values would "successfully" key the pool to a
    # value every identical machine reports -- or to nothing at all --
    # and the mistake only surfaces when unlocking fails later.
    case "$KEY" in
      ${lib.concatStringsSep " | " ([ "\"\"" ] ++ junkPatterns)} )
        echo "zfs key file: the key source returned an empty or placeholder value ('$KEY'); refusing to derive a ZFS encryption key from it" >&2
        exit 1
        ;;
    esac

    # A leftover NON-directory here (a file, or a dangling symlink)
    # would make the mkdir below fail, so it is removed; an existing
    # directory is kept and its key file simply overwritten.
    if ! [ -d "$SECRET_FOLDER_PATH" ]; then
      rm -rf "$SECRET_FOLDER_PATH"
    fi

    mkdir -p "$SECRET_FOLDER_PATH"
    chmod 700 "$SECRET_FOLDER_PATH"

    # printf, never `echo -n` or a here-string: the key must land in the
    # file verbatim, with no trailing newline.
    printf '%s' "$KEY" > "$KEY_FILE_PATH"
  '';

  checkedKeySourceCommand =
    functionName: keySourceCommand:
    if keySourceCommand == null || lib.isString keySourceCommand then
      keySourceCommand
    else
      throw "The argument `keySourceCommand` must be `null` (use the predefined per-platform key source) or a string (a POSIX-sh snippet that sets `KEY`), but is a value of type `${builtins.typeOf keySourceCommand}`";

  # Chooses where `KEY` comes from: the caller's own `keySourceCommand`
  # if given (ANY platform, used verbatim); otherwise the predefined
  # per-platform source. `dmidecodeInvocation` -- the ONE thing that
  # still varies by SITE rather than by platform -- is threaded in by
  # each call site rather than hardcoded here: a live-installer
  # environment needs a `which`-guarded fallback to `nix run`, a
  # systemd-initrd service relies on `extraBin` staging `dmidecode` onto
  # PATH, and a script-initrd hook references the absolute store path
  # directly (no PATH, no `nix`, in that environment) -- collapsing
  # these into one shared string would either lose the live-installer
  # fallback or hand the other contexts an invocation that cannot work
  # in them. The aarch64-linux and custom-override branches have no
  # such per-site variation: `/proc/cpuinfo` has no availability/PATH
  # concerns in any context, and a caller's snippet is spliced in
  # verbatim wherever it is used.
  keySourceFor =
    {
      functionName,
      keySourceCommand,
      dmidecodeInvocation,
    }:
    let
      checked = checkedKeySourceCommand functionName keySourceCommand;
    in
    if checked != null then
      {
        script = checked;
        junkPatterns = [ ];
      }
    else if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
      {
        script = dmidecodeInvocation;
        junkPatterns = dmidecodeJunkPatterns;
      }
    else if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
      {
        # `Serial` appears exactly once in /proc/cpuinfo -- after the
        # last per-core block -- regardless of core count, so a single
        # match is always correct.
        script = ''
          KEY="$(awk -F': *' '/^Serial/{print $2}' /proc/cpuinfo | tr -d '\n')"
        '';
        junkPatterns = cpuinfoSerialJunkPatterns;
      }
    else
      throw "${functionName}: `enableEncryption = true` has no predefined key source for `${pkgs.stdenv.hostPlatform.system}` -- supply your own via `keySourceCommand`.";
in
{
  inherit
    dmidecodeJunkPatterns
    cpuinfoSerialJunkPatterns
    writeKeyFile
    checkedKeySourceCommand
    keySourceFor
    ;
}
