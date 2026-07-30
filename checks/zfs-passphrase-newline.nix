# Does ZFS care about a trailing newline in a `keyformat=passphrase` key
# file? Answered by booting a VM with real ZFS and round-tripping an
# encrypted pool.
#
# ANSWER (verified by this check): it does NOT. ZFS strips a single
# trailing newline, so all four create/import combinations below load the
# key successfully.
#
# This is the question declareZfsRootDisk's key file used to depend on by
# accident: pool creation wrote the passphrase with a trailing newline (a
# here-string) while both boot paths wrote it without one (echo -n). That
# drift was therefore harmless in practice -- worth knowing, because it is
# the difference between "we had a latent unlockable-pool bug" and "we had
# an inconsistency". The writers were unified anyway (one definition,
# deterministic bytes, pinned by checks/zfs-key-file.nix) rather than
# leaving correctness resting on this ZFS detail; this check is what makes
# that detail a checked fact instead of an assumption.
#
# No disko involved: a file-backed vdev is enough, and the encryption root
# is the pool itself.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "zfs-passphrase-newline";

  nodes.machine = {
    boot.supportedFilesystems.zfs = true;
    # ZFS lags the newest kernel; the LTS one is always supported.
    boot.kernelPackages = pkgs.linuxPackages;
    # required by ZFS
    networking.hostId = "deadbeef";
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("modprobe zfs")

    KEY = "0123456789abcdef-passphrase"
    WITH_NEWLINE = f"printf '%s\\n' '{KEY}'"
    NO_NEWLINE = f"printf '%s' '{KEY}'"

    def probe(create_writer, import_writer):
        """Create an encrypted pool with one key writer, export it, rewrite
        the SAME key file with the other writer, and try to import -l."""
        machine.execute("zpool destroy -f testpool")
        machine.succeed("rm -f /var/lib/pool.img")
        machine.succeed("truncate -s 128M /var/lib/pool.img")
        machine.succeed("mkdir -p /tmp/secrets")

        machine.succeed(f"{create_writer} > /tmp/secrets/zpool.key")
        machine.succeed(
            "zpool create -f -O encryption=on -O keyformat=passphrase "
            "-O keylocation=file:///tmp/secrets/zpool.key "
            "testpool /var/lib/pool.img"
        )
        machine.succeed("zpool export testpool")

        machine.succeed(f"{import_writer} > /tmp/secrets/zpool.key")
        rc, out = machine.execute("zpool import -d /var/lib -l testpool 2>&1")
        machine.execute("zpool export testpool")
        print(f"import rc={rc}: {out.strip()}")
        return rc == 0

    same_nl = probe(WITH_NEWLINE, WITH_NEWLINE)
    same_none = probe(NO_NEWLINE, NO_NEWLINE)
    created_nl = probe(WITH_NEWLINE, NO_NEWLINE)
    created_none = probe(NO_NEWLINE, WITH_NEWLINE)

    print("=== ZFS passphrase key file, trailing newline ===")
    print(f"create \\n / import \\n  -> {same_nl}")
    print(f"create    / import     -> {same_none}")
    print(f"create \\n / import     -> {created_nl}")
    print(f"create    / import \\n  -> {created_none}")

    # Sanity: a key file that does not change between create and import must
    # always work, whichever writer produced it.
    assert same_nl, "identical key file with a trailing newline failed to import"
    assert same_none, "identical key file without a trailing newline failed to import"

    # The finding, asserted so a CHANGE in ZFS behavior surfaces here rather
    # than on a machine that will not boot: both cross cases load the key, so
    # ZFS strips the trailing newline and the two spellings are equivalent.
    assert created_nl, (
        "a pool created with a trailing newline in the key file could NOT be "
        "imported with the newline-free key file -- ZFS does NOT strip it, so "
        "the three key writers in declareZfsRootDisk must agree byte for byte "
        "or the pool is unlockable"
    )
    assert created_none, (
        "a pool created without a trailing newline could NOT be imported with "
        "a trailing-newline key file"
    )
  '';
}
