# Behavior test for declareZfsDataDisk's encryption key units, run by
# `nix flake check`. No VM and no real ZFS needed.
#
# Two things are exercised, both the REAL generated scripts (not copies):
#
#   - the key-writer service's script -- same shared writer/junk-validation
#     `declareZfsRootDisk` uses (see lib/disko/internal/hardware-key.nix),
#     so this mirrors checks/zfs-key-file.nix's junk cases rather than
#     duplicating their reasoning.
#   - the migrate service's script -- run against FAKE `zfs`/`zpool`
#     binaries (config.boot.zfs.package points at them) that record what
#     they were called with, so the test can assert `zfs change-key` fires
#     exactly when it should and never otherwise.
{ pkgs, myLib }:
let
  lib = pkgs.lib;

  uuid = "4C4C4544-0042-4210-8057-B4C04F503332";

  stub = pkgs.writeShellScriptBin "dmidecode" ''
    echo "${uuid}"
  '';
  stubBin = "${stub}/bin/dmidecode";

  # A fake `zfs`/`zpool` pair, laid out like the real ZFS package
  # (`$out/sbin/{zfs,zpool}`, matching `config.boot.zfs.package`'s own
  # shape) -- `zfsPackageBin` in the implementation interpolates
  # `${config.boot.zfs.package}/sbin/<bin>` directly into the generated
  # script, so pointing that option at this fake package is enough to
  # redirect every `zfs`/`zpool` call the migrate script makes, with no
  # sed substitution needed (unlike dmidecode, which is a bare command
  # name in the snippet).
  #
  # `zpool` always succeeds (the pool is always "there" for these
  # scenarios -- the not-imported case is a separate, simpler eval-time
  # concern, not this test's point). `zfs get ... keylocation` answers
  # with $FAKE_KEYLOCATION (set per scenario below, not baked into the
  # package); `zfs change-key ...` appends its full argument list to
  # ./zfs-change-key.log in the CURRENT directory (the test always `cd`s
  # into its own scratch dir first), so a scenario can assert whether --
  # and with what arguments -- it fired.
  fakeZfsPkg = pkgs.runCommand "fake-zfs" { } ''
    mkdir -p $out/sbin
    cat > $out/sbin/zpool <<'SCRIPT'
    #!/bin/sh
    exit 0
    SCRIPT
    cat > $out/sbin/zfs <<'SCRIPT'
    #!/bin/sh
    if [ "$1" = "get" ]; then
      echo "$FAKE_KEYLOCATION"
      exit 0
    elif [ "$1" = "change-key" ]; then
      echo "$@" >> ./zfs-change-key.log
      exit 0
    fi
    exit 1
    SCRIPT
    chmod +x $out/sbin/zpool $out/sbin/zfs
  '';

  buildModule =
    args:
    (myLib.declareZfsDataDisk (
      {
        name = "bulk";
        vdevs = [
          {
            mode = null;
            devicePaths = [ "/dev/disk/by-id/d1" ];
          }
        ];
      }
      // args
    ))
      {
        inherit pkgs lib;
        config.boot.zfs.package = fakeZfsPkg;
      };

  defaultKeyFilePath = "/run/zfs-data-disk-secrets/zpool.key";

  moduleDefault = buildModule { };
  keyWriterScript = moduleDefault.systemd.services."zfs-data-key-zdata-bulk".script;
  poolCreateScript = moduleDefault.disko.devices.zpool."zdata-bulk".preCreateHook;

  sedArgs = ''
    -e "s|/nix/store/[^ ]*/bin/dmidecode|${stubBin}|g" \
        -e "s|(dmidecode |(${stubBin} |g" \
        -e "s|/run/zfs-data-disk-secrets|$work/secrets|g"'';

  # preCreateHook (unlike the key-writer service above, which always has
  # dmidecode on PATH via NixOS's own `path` option) runs during disko
  # install, in whatever environment nixos-anywhere or an install ISO
  # provides -- so it probes with `which` and falls back to `nix run` if
  # dmidecode is not there. Mirrors checks/zfs-key-file.nix's own
  # `fallbackCase`/experimental-features regression test for
  # `declareZfsRootDisk` -- this exact code path had NO coverage at all
  # before, and it broke on a real `nixos-anywhere` deployment (a bare
  # `nix run`, no `--extra-experimental-features`, failed outright against
  # the kexec installer's own nix.conf).
  sedArgsPoolCreate = ''
    ${sedArgs} \
        -e "s|which dmidecode|which ${stubBin}|g"'';

  poolCreateWritesRealKey = ''
    echo "=== data-disk pool-create: writes the real key on good input (dmidecode on PATH)"
    work="$TMPDIR/pool-create-ok"
    mkdir -p "$work"
    sed ${sedArgsPoolCreate} ${pkgs.writeText "pool-create.sh" poolCreateScript} > "$work/run.sh"
    ( cd "$work" && bash ./run.sh )
    printf '%s' '${uuid}' | cmp - "$work/secrets/zpool.key"
  '';

  poolCreateFallbackCase = ''
    echo "=== data-disk pool-create: falls back to nix run (dmidecode not on PATH)"
    work="$TMPDIR/pool-create-fallback"
    mkdir -p "$work"
    sed ${sedArgsPoolCreate} \
        -e "s|which ${stubBin}|false|g" \
        -e "s|nix --extra-experimental-features 'nix-command flakes' run nixpkgs#dmidecode --|${stubBin}|g" \
        ${pkgs.writeText "pool-create-fallback.sh" poolCreateScript} > "$work/run.sh"
    ( cd "$work" && bash ./run.sh )
    printf '%s' '${uuid}' | cmp - "$work/secrets/zpool.key"
  '';

  poolCreateFallbackHasExperimentalFeaturesFlag = ''
    echo "=== data-disk pool-create: nix run fallback carries its own experimental-features flag"
    grep -q -- "--extra-experimental-features 'nix-command flakes' run" \
      ${pkgs.writeText "pool-create-raw.sh" poolCreateScript}
  '';

  # ── key-writer: refuses junk, same shared validation as the root disk ──
  junkStub =
    junk:
    pkgs.writeShellScriptBin "dmidecode" ''
      echo "${junk}"
    '';
  junkCase = slug: junk: ''
    echo "=== junk uuid (${slug}): the data-disk key writer refuses"
    work="$TMPDIR/junk-${slug}"
    mkdir -p "$work"
    sed ${sedArgs} \
        -e "s|${stubBin}|${junkStub junk}/bin/dmidecode|g" \
        ${pkgs.writeText "junk-writer-${slug}.sh" keyWriterScript} > "$work/run.sh"
    rc=0
    ( cd "$work" && bash ./run.sh ) 2> "$work/err" || rc=$?
    [ "$rc" -ne 0 ]
    grep -q "refusing" "$work/err"
    [ ! -e "$work/secrets/zpool.key" ]
  '';

  keyWriterWritesRealKey = ''
    echo "=== data-disk key writer: writes the real key on good input"
    work="$TMPDIR/writer-ok"
    mkdir -p "$work"
    sed ${sedArgs} ${pkgs.writeText "writer.sh" keyWriterScript} > "$work/run.sh"
    ( cd "$work" && bash ./run.sh )
    printf '%s' '${uuid}' | cmp - "$work/secrets/zpool.key"
  '';

  # ── migrate: fires only when (stale keylocation) AND (target exists) ──
  customKeyFilePath = "/run/secrets/zdata-bulk.key";
  moduleCustomKey = buildModule { keyFilePath = customKeyFilePath; };
  migrateScript = moduleCustomKey.systemd.services."zfs-data-key-migrate-zdata-bulk".script;

  runMigrate =
    {
      slug,
      # "default" -- current keylocation is still the ephemeral default
      # (the only case that should ever migrate); "migrated" -- current
      # keylocation already points at the (post-substitution) target
      # path, computed from `$work` at SHELL runtime so it can never
      # drift from the path the sed substitution below actually uses.
      keylocationMode,
      targetExists,
    }:
    ''
      echo "=== migrate (${slug})"
      work="$TMPDIR/migrate-${slug}"
      mkdir -p "$work"
      ${lib.optionalString targetExists ''
        mkdir -p "$(dirname "$work${customKeyFilePath}")"
        printf 'the-real-key' > "$work${customKeyFilePath}"
      ''}
      sed -e "s|${customKeyFilePath}|$work${customKeyFilePath}|g" \
          ${pkgs.writeText "migrate-${slug}.sh" migrateScript} > "$work/run.sh"
      ${
        if keylocationMode == "default" then
          ''fake_keylocation="file://${defaultKeyFilePath}"''
        else
          ''fake_keylocation="file://$work${customKeyFilePath}"''
      }
      ( cd "$work" && FAKE_KEYLOCATION="$fake_keylocation" bash ./run.sh )
    '';

  migrateFires = runMigrate {
    slug = "stale-and-target-exists";
    keylocationMode = "default";
    targetExists = true;
  };
  migrateSkipsAlreadyMigrated = runMigrate {
    slug = "already-migrated";
    keylocationMode = "migrated";
    targetExists = true;
  };
  migrateSkipsMissingTarget = runMigrate {
    slug = "target-missing";
    keylocationMode = "default";
    targetExists = false;
  };
in
pkgs.runCommand "zfs-data-key-file-test"
  {
    # preCreateHook's happy path probes for dmidecode with `which`, which is
    # not in the stdenv PATH; provide it rather than skipping the branch
    # (its absence is covered by poolCreateFallbackCase below).
    nativeBuildInputs = [ pkgs.which ];
  }
  ''
    ${keyWriterWritesRealKey}

    ${poolCreateWritesRealKey}
    ${poolCreateFallbackCase}
    ${poolCreateFallbackHasExperimentalFeaturesFlag}

    ${junkCase "empty" ""}
    ${junkCase "not-settable" "Not Settable"}

    ${migrateFires}
    [ -e "$TMPDIR/migrate-stale-and-target-exists/zfs-change-key.log" ]
    grep -q -- "-o keylocation=file://$TMPDIR/migrate-stale-and-target-exists${customKeyFilePath}" \
      "$TMPDIR/migrate-stale-and-target-exists/zfs-change-key.log"
    grep -q -- "-o keyformat=passphrase" "$TMPDIR/migrate-stale-and-target-exists/zfs-change-key.log"
    grep -q -- "zdata-bulk" "$TMPDIR/migrate-stale-and-target-exists/zfs-change-key.log"

    ${migrateSkipsAlreadyMigrated}
    [ ! -e "$TMPDIR/migrate-already-migrated/zfs-change-key.log" ]

    ${migrateSkipsMissingTarget}
    [ ! -e "$TMPDIR/migrate-target-missing/zfs-change-key.log" ]

    touch $out
  ''
