# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ lib, self, ... }:
{
  /**
    Shadow one binary from a package on `PATH`, routing matching
    invocations through `detachedRun` and everything else straight to the
    real binary. Built to fix commands like `home-manager switch` whose
    OWN effects can kill the shell that invoked them (see `detachedRun`'s
    doc comment for the mechanism and why); use this when that wrapping
    needs to happen wherever the plain command name is typed, not just at
    one fixed call site.

    The wrapper's `bin/<binary>` wins name resolution via `lib.hiPrio`,
    but everything else the real package ships (shell completions, other
    binaries, ...) still comes from it: `symlinkJoin` merges the two,
    priority only breaks the naming conflict on `binary` itself.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    environment.systemPackages = [
      (extLib.systemd.interceptingWrapper pkgs {
        package = pkgs.home-manager;
        binary = "home-manager";
        # detach only `home-manager switch`; every other subcommand
        # (news, generations, ...) passes straight through
        shouldDetach = ''[ "${1:-}" = "switch" ]'';
        label = "hm-switch";
      })
    ];
    ```

    # Type

    ```
    interceptingWrapper :: pkgs -> Attribute -> Derivation
    ```

    # Arguments

    pkgs
    : The package set used to build the wrapper and passed through to
    : `detachedRun`.

    package
    : The real package to wrap, e.g. `pkgs.home-manager`.

    binary
    : Which binary inside `package` to shadow (`${package}/bin/${binary}`)
    : -- also the wrapper's own `writeShellScriptBin` name, so it is what
    : actually wins on `PATH`.

    shouldDetach
    : Raw shell syntax for the condition to detach on, checked against the
    : wrapper's own positional parameters (`$1`, `$@`, ...) -- e.g.
    : `''[ "${1:-}" = "switch" ]''`. True routes through `detachedRun`;
    : false `exec`s the real binary with the same arguments. Not a
    : Nix-modeled argv list: Nix cannot see the caller's real arguments,
    : only shell can, at the moment the wrapper actually runs.

    label
    : Passed straight through to `detachedRun` -- see its own doc comment.
    : Default: `binary` (already a valid unit-name component).

    extraEnv
    : Passed straight through to `detachedRun`. Default `[ ]`.

    extraProperties
    : Passed straight through to `detachedRun`. Default `[ ]`.
  */
  interceptingWrapper =
    pkgs:
    {
      package,
      binary,
      shouldDetach,
      label ? binary,
      extraEnv ? [ ],
      extraProperties ? [ ],
    }:
    let
      wrapper = pkgs.writeShellScriptBin binary ''
        real=${package}/bin/${binary}
        if ${shouldDetach}; then
          ${self.systemd.detachedRun pkgs {
            inherit
              label
              extraEnv
              extraProperties
              ;
            command = ''"$real" "$@"'';
          }}
        else
          exec "$real" "$@"
        fi
      '';
    in
    pkgs.symlinkJoin {
      name = "${binary}-wrapped";
      paths = [
        (pkgs.lib.hiPrio wrapper)
        package
      ];
    };
}
