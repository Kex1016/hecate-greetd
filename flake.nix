{
  description = "hecate-greetd: greetd greeter that is hecate's own lock screen";

  inputs = {
    # The compositor and the shell whose lock screen this is. git+https so a private repo is
    # fetched with git's credentials.
    hecate.url = "git+https://github.com/Kex1016/wl-hex?shallow=1";
    nixpkgs.follows = "hecate/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      hecate,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system} system);
    in
    {
      packages = forAllSystems (
        pkgs: system: rec {
          hecate-greetd = pkgs.callPackage ./nix/package.nix {
            hecate = hecate.packages.${system}.hecate;
            hecate-shell = hecate.packages.${system}.hecate-shell.override {
              extraPackages = [ hecate.packages.${system}.hecate ];
            };
          };
          default = hecate-greetd;
        }
      );

      nixosModules.default = import ./nix/nixos-module.nix { inherit self hecate; };

      checks = forAllSystems (
        pkgs: system: {
          inherit (self.packages.${system}) hecate-greetd;
          # The module evaluates and its compositor config validates.
          module =
            (lib.nixosSystem {
              inherit system;
              modules = [
                hecate.nixosModules.default
                self.nixosModules.default
                {
                  programs.hecate.enable = true;
                  services.hecate-greetd.enable = true;
                  users.users.alice.isNormalUser = true;
                  fileSystems."/" = {
                    device = "/dev/null";
                    fsType = "ext4";
                  };
                  boot.loader.grub.enable = false;
                  system.stateVersion = "26.05";
                }
              ];
            }).config.system.build.toplevel;
        }
      );

      devShells = forAllSystems (
        pkgs: _: {
          default = pkgs.mkShell {
            packages = with pkgs; [
              cargo
              rustc
              clippy
              rustfmt
              rust-analyzer
            ];
          };
        }
      );

      formatter = forAllSystems (pkgs: _: pkgs.nixfmt);
    };
}
