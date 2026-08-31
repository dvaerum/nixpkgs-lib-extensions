# nixpkgs-patching-empty-dir

Deliberately has no applicable `.patch`/`.nix` files -- used by
checks/nixpkgs-patching.nix to assert that a `patches` directory
expanding to `[ ]` does not force a patched-tree rebuild at all.
