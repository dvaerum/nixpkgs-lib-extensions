# Intro

Some extra functions not originally in `nixpkgs.lib` which I find useful.
Some I wrote myself and some I found on the internet.

**Documentaion:** can be found [docs/lib.md](docs/lib.md)

# Use the extra libary

Here are 3 different host examples for how it include the extra libary
into a nixos config.

```
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixpkgs-lib-extensions = {
      url = "git+https://github.com/dvaerum/nixpkgs-lib-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, nixpkgs-lib-extensions, ... }:
  let
    system = "x86_64-linux";

  in {
    # Directly import into `lib` by merging them together
    nixosConfigurations.host_1 = nixpkgs.lib.nixosSystem {
      inherit system;

      lib = nixpkgs.lib.extend (final: prev:
        nixpkgs-lib-extensions.extendLib prev
      );
      
      modules = [
        ./configuration.nix
      ];
    };

    # Expose the extra library as `extLib` to the function args
    nixosConfigurations.host_2 = import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      
      specialArgs = {
        extLib = nixpkgs-lib-extensions.lib;
      };
      
      modules = [
        ./configuration.nix
      ];
      
      
    };

    # Same as for `host_1` just an example there `eval-config.nix` us used
    # instead of lib.nixosSystem
    nixosConfigurations.host_3 = import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;

      lib = nixpkgs.lib.extend (final: prev:
        nixpkgs-lib-extensions.extendLib prev
      );

      modules = [
        ./configuration.nix
      ];
    };
  };
}
```
