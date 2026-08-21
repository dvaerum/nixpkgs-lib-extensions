# Loaded by lib/default.nix under the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
{ lib, ... }:
{
  /**
    Read a path as plain text, but only when it is NOT still git-crypt
    ciphertext; otherwise return `default` instead of aborting evaluation.
    `readIfPlain` is the same function with the default fixed to `""`.

    Companion to `importIfNixOr`/`importIfNix` for files that are not Nix
    -- a plain secret, token, or config value protected by git-crypt
    (which encrypts individual files in a git repo transparently -- a
    checkout without the decryption key sees raw ciphertext instead of
    the file's real content). Locally (key present) git-crypt's smudge
    filter has already replaced the working-tree file with real
    plaintext, and this returns it as a string. On a checkout without the
    key, the working-tree file is still git-crypt's raw ciphertext --
    `builtins.readFile` on that would likely THROW (its bytes are not
    valid UTF-8) rather than return usable garbage, so the ciphertext is
    detected BEFORE ever calling `readFile` on it.

    Detection does not depend on the plaintext's content being valid Nix
    (there may be none to parse): a git-crypt-encrypted file always
    begins with the same fixed 10-byte header (a NUL byte, `GITCRYPT`,
    another NUL byte), whatever the plaintext underneath actually is.
    That header is checked byte-for-byte in a small derivation
    (import-from-derivation, `preferLocalBuild`) -- IFD, like
    `importIfNixOr`'s parse probe, just testing a fixed magic value
    instead of running a Nix parser.

    Accepted: a regular file whose first bytes are not that header.
    Symlinks are followed and classified by what they resolve to (a link
    to such a file reads like its target; a dangling link counts as
    missing). Everything else -- a missing path, a directory, or
    genuine git-crypt ciphertext -- yields `default` WITH an evaluation
    warning naming the reason, so a skipped read is never a silent
    mystery.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.readIfPlainOr pkgs ./api-token.txt ""
    # locally (key present)    => "sk-abc123...\n"
    # on CI (still encrypted)  => "" (warns)
    ```

    # Type

    ```
    readIfPlainOr :: pkgs -> Path -> String -> String
    ```

    # Arguments

    pkgs
    : A package set used to build the header-check probe (IFD).

    path
    : The path (or absolute path string) to inspect and maybe read.

    default
    : The value returned (with a warning) when `path` is still
    : git-crypt ciphertext, missing, or not a regular file.
  */
  readIfPlainOr =
    pkgs: path: default:
    let
      type = if lib.pathExists path then builtins.readFileType path else null;

      # Same symlink-resolution logic as importIfNixOr: readFileType alone
      # reports "symlink" without following it, so a link is reclassified
      # by what it resolves to (stat'ing a literal trailing "/." succeeds
      # exactly when the target is a directory). Dangling links never
      # reach here -- the pathExists guard above already called them missing.
      resolvedType =
        if type != "symlink" then
          type
        else if builtins.pathExists (toString path + "/.") then
          "directory"
        else
          "regular";

      skip =
        reason: lib.warn "readIfPlainOr: ${toString path} ${reason}; using the default instead" default;

      # Flat store copy so a final-component symlink is followed rather
      # than copied as a dangling link inside the build sandbox -- same
      # reasoning as importIfNixOr's probeSrc.
      probeSrc =
        file:
        builtins.path {
          path = file;
          recursive = false;
          name = "read-if-plain-probe";
        };

      # git-crypt's own format: every encrypted blob begins with this
      # fixed 10-byte header regardless of the plaintext underneath (a
      # NUL byte, the ASCII string "GITCRYPT", another NUL byte).
      isGitCrypted =
        file:
        lib.readFile (
          pkgs.runCommand "is-git-crypted"
            {
              preferLocalBuild = true;
              allowSubstitutes = false;
            }
            ''
              printf '\0GITCRYPT\0' > magic
              if head -c 10 -- "${probeSrc file}" | cmp -s - magic; then
                printf yes > $out
              else
                printf no > $out
              fi
            ''
        ) == "yes";
    in
    if type == null then
      skip "does not exist"
    else if resolvedType != "regular" then
      skip "is not a regular file"
    else if isGitCrypted path then
      skip "is still git-crypt ciphertext"
    else
      builtins.readFile path;
}
