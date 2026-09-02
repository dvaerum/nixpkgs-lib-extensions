A directory with no `.nix` files at all.

Used by checks/builders/tests/registry.nix (malformed-user-directory-skipped)
to verify such a directory is SKIPPED with a warning rather than becoming a
user, and by checks/lib-functions.nix for importIfNix's "directory without a
default.nix" case.
