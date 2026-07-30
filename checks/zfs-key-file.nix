# Behavior test for declareZfsRootDisk's encryption key file, run by
# `nix flake check`. No VM and no ZFS needed.
#
# The key file (/tmp/secrets/zpool.key) is written in THREE places: at pool
# creation (the zpool's preCreateHook) and at boot by either initrd flavor.
# The passphrase `zpool create` stores is what `zfs load-key` has to
# reproduce, so all three must write byte-identical files -- and they had
# drifted once already (a here-string appends a newline, `echo -n` does not).
#
# The REAL generated scripts are exercised, not a copy of them: they are
# pulled out of the module and run in the sandbox with two hermetic
# substitutions -- `dmidecode` becomes a stub with a known UUID, and the
# hard-coded /tmp/secrets is moved into $TMPDIR so the test cannot touch a
# real /tmp on a machine that builds without the sandbox.
#
# What this does NOT prove: whether ZFS itself tolerates a trailing newline
# in a `keyformat=passphrase` key file. Only creating and re-importing a real
# encrypted pool answers that, which needs a VM with the ZFS kernel module.
{ pkgs, myLib }:
let
  lib = pkgs.lib;

  # A plausible `dmidecode --string system-uuid` value.
  uuid = "4C4C4544-0042-4210-8057-B4C04F503332";

  # The real tool prints the UUID with a trailing newline; every caller pipes
  # it through `tr -d '\n'`, so the stub keeps that shape deliberately.
  stub = pkgs.writeShellScriptBin "dmidecode" ''
    echo "${uuid}"
  '';
  stubBin = "${stub}/bin/dmidecode";

  module =
    (myLib.declareZfsRootDisk {
      devicePath = "/dev/disk/by-id/test-disk";
      hostname = "testhost";
      listOfUsernames = [ "alice" ];
    })
      {
        inherit pkgs lib;
        config.boot.initrd.systemd.enable = true;
      };

  # The three writers. The two initrd ones sit behind `lib.mkIf`, so the
  # string lives under `.content`.
  writers = {
    pool-create = module.disko.devices.zpool."zroot-testhost".preCreateHook;
    systemd-initrd = module.boot.initrd.systemd.content.services.zfs-key-file-setup.script;
    script-initrd = module.boot.initrd.postDeviceCommands.content;
  };

  # Precise substitutions: a loose `[^ ]*dmidecode` would also swallow the
  # `KEY="$(` in front of it.
  sedArgs = ''
    -e "s|/nix/store/[^ ]*/bin/dmidecode|${stubBin}|g" \
        -e "s|(dmidecode |(${stubBin} |g" \
        -e "s|which dmidecode|which ${stubBin}|g" \
        -e "s|nix run nixpkgs#dmidecode --|${stubBin}|g" \
        -e "s|/tmp/secrets|$work/secrets|g"'';

  # Run one writer on a clean slate and check the bytes it produced.
  runOne = name: text: ''
    echo "=== writer: ${name}"
    work="$TMPDIR/${name}"
    mkdir -p "$work"
    sed ${sedArgs} ${pkgs.writeText "writer-${name}.sh" text} > "$work/run.sh"
    ( cd "$work" && bash ./run.sh )

    key="$work/secrets/zpool.key"
    # EXACTLY the uuid: no trailing newline, nothing else
    [ "$(wc -c < "$key")" -eq ${toString (builtins.stringLength uuid)} ]
    printf '%s' '${uuid}' | cmp - "$key"
    # and the folder holding it is private
    [ "$(stat -c %a "$work/secrets")" = 700 ]

    cp "$key" "$TMPDIR/bytes-${name}"
  '';

  # preCreateHook has TWO ways to reach dmidecode: the tool is on PATH
  # (`which` succeeds -- covered by runOne above), or it is not, which happens
  # in a kexec image or when booting an installer ISO, and it falls back to
  # `nix run`. Force the second branch by making the availability check fail.
  fallbackCase = ''
    echo "=== writer: pool-create (dmidecode not on PATH)"
    work="$TMPDIR/pool-create-fallback"
    mkdir -p "$work"
    sed ${sedArgs} \
        -e "s|which ${stubBin}|false|g" \
        ${pkgs.writeText "writer-fallback.sh" writers.pool-create} > "$work/run.sh"
    ( cd "$work" && bash ./run.sh )
    printf '%s' '${uuid}' | cmp - "$work/secrets/zpool.key"
  '';

  # Run one writer against a pre-existing state, to pin what the
  # `if ! [[ -d ... ]]; then rm -rf ...; fi` guard is actually for.
  guardCase = name: setup: ''
    echo "=== guard: ${name}"
    work="$TMPDIR/guard-${name}"
    mkdir -p "$work"
    sed ${sedArgs} ${pkgs.writeText "guard-writer.sh" writers.systemd-initrd} > "$work/run.sh"
    ${setup}
    ( cd "$work" && bash ./run.sh )
    [ -d "$work/secrets" ]
    [ "$(stat -c %a "$work/secrets")" = 700 ]
    printf '%s' '${uuid}' | cmp - "$work/secrets/zpool.key"
  '';
in
pkgs.runCommand "zfs-key-file-test"
  {
    # preCreateHook probes for dmidecode with `which`, which is not in the
    # stdenv PATH; a real host has it, so provide it rather than skipping the
    # branch (its absence is covered by fallbackCase below).
    nativeBuildInputs = [ pkgs.which ];
  }
  ''
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList runOne writers)}
    ${fallbackCase}

    # THE invariant: pool creation and both boot paths agree byte for byte
    cmp "$TMPDIR/bytes-pool-create" "$TMPDIR/bytes-systemd-initrd"
    cmp "$TMPDIR/bytes-pool-create" "$TMPDIR/bytes-script-initrd"

    # a leftover regular FILE where the folder belongs is removed (mkdir would
    # otherwise fail)
    ${guardCase "stale-file" ''printf x > "$work/secrets"''}

    # ... as is a dangling symlink (`-d` is false for it, `rm -rf` takes it)
    ${guardCase "dangling-symlink" ''ln -s "$work/nowhere" "$work/secrets"''}

    # ... while an existing DIRECTORY is kept: its stale key file is
    # overwritten and its mode tightened, so keeping it is safe
    ${guardCase "existing-dir-stale-key" ''
      mkdir -p "$work/secrets"
      printf STALE-KEY > "$work/secrets/zpool.key"
      chmod 777 "$work/secrets"
    ''}

    touch $out
  ''
