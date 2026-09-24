{
  description = "codecrafters-redis-haskell dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            stack
            ghc
            haskell-language-server
            zlib
            pkg-config

            # Reference implementation, for differential testing: run the same
            # command sequence against redis-server and against ours, compare
            # replies. Also gives redis-cli for poking at either by hand.
            redis
          ];

          # Stack manages its own GHC/package snapshot per stack.yaml;
          # keep it from also reaching for Nix so the two don't fight.
          STACK_YAML = "stack.yaml";
          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.zlib}/lib:$LD_LIBRARY_PATH"
          '';
        };
      });
}
