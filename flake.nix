{
  description = "A hello world unikernel";

  inputs.nixpkgs.url = "github:nixos/nixpkgs";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.flake-utils.inputs.nixpkgs.follows = "nixpkgs";

  inputs.opam-nix.url = "github:tweag/opam-nix";
  inputs.opam-nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.opam-nix.inputs.flake-utils.follows = "flake-utils";

  inputs.opam2json.url = "github:tweag/opam2json";
  inputs.opam2json.inputs.nixpkgs.follows = "nixpkgs";
  inputs.opam-nix.inputs.opam2json.follows = "opam2json";

  # beta so pin commit
  inputs.nix-filter.url = "github:numtide/nix-filter/3e1fff9";

  inputs.opam-repository = {
    url = "github:ocaml/opam-repository";
    flake = false;
  };
  inputs.opam-nix.inputs.opam-repository.follows = "opam-repository";
  inputs.opam-overlays = {
    url = "github:dune-universe/opam-overlays";
    flake = false;
  };

  outputs = { self, nixpkgs, flake-utils, opam-nix, opam2json, nix-filter, opam-repository, opam-overlays, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (opam-nix.lib.${system})
          buildOpamProject' queryToScope opamRepository;
      in {
        legacyPackages = let

          # Stage 1: run `mirage configure` on source
          # with mirage, dune, and ocaml from `opam-nix`
          configureSrcFor = target:
            let configure-scope = queryToScope { } { mirage = null; }; in
            pkgs.stdenv.mkDerivation {
              name = "configured-src";
              # only copy these files
              # means only rebuilds when these files change
              src = with nix-filter.lib;
                filter {
                  root = self;
                  include = [
                    "config.ml"
                    "unikernel.ml"
                  ];
                };
              buildInputs = with configure-scope; [ mirage ];
              nativeBuildInputs = with configure-scope; [ dune ocaml ];
              phases = [ "unpackPhase" "configurePhase" "installPhase" "fixupPhase" ];
              configurePhase = ''
                mirage configure -t ${target}
                # Rename the opam file for package name consistency
                # And move to root so a recursive search for opam files isn't required
                cp mirage/hello-${target}.opam hello.opam
              '';
              installPhase = "cp -R . $out";
            };

          # Stage 2: read all the opam files from the configured source, and build the hello package
          mkScope = src:
            let
              scope = buildOpamProject'
                {
                  # pass monorepo = 1 to `opam admin list` to pick up dependencies marked with {?monorepo}
                  resolveArgs.env.monorepo = 1;
                  repos = [ opam-repository opam-overlays ];
                }
                src
                { conf-libseccomp = null; };
              overlay = final: prev: {
                hello = (prev.hello.override {
                  # Gets opam-nix to pick up dependencies marked with {?monorepo}
                  extraVars.monorepo = true;
                }).overrideAttrs (_: { inherit src; });
              };
            in scope.overrideScope' overlay;

          virtio-overlay = final: prev: {
            hello = (prev.hello.override { } ).overrideAttrs (_ : {
              preBuild = ''
                export OCAMLFIND_CONF="${final.ocaml-solo5}/lib/findlib.conf"
              '';
              phases = [ "unpackPhase" "preBuild" "buildPhase" "installPhase" ];
              buildPhase = ''
                dune build
              '';
            });
          };

        in {
          unix = mkScope (configureSrcFor "unix");
          virtio = (mkScope (configureSrcFor "virtio")).overrideScope' virtio-overlay;
        };

        defaultPackage = self.legacyPackages.${system}.unix.hello;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            gcc
            bintools-unwrapped
            gmp
          ];
        };
      });
}

