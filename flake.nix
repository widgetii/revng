# TODO: try on macmini

{
  inputs = {
    nixpkgs.url = "git+file:///home/ale/nixpkgs-master";

    nixpkgs-2505.url = "https://github.com/NixOS/nixpkgs/archive/refs/heads/nixos-25.05-small.tar.gz";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-2505,
      poetry2nix,
      uv2nix,
      pyproject-nix,
      pyproject-build-systems,
    }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs { inherit system; };
      pkgs-2505 = import nixpkgs-2505 { inherit system; };

      # Adopt:
      #
      # * clang as a compiler
      # * libc++ as C++ standard library
      # * mold as linker
      stdenv = (pkgs.useMoldLinker pkgs.llvmPackages_21.libcxxStdenv);

      #
      # Build C++ dependencies using our stdenv
      #
      boost-test =
        (pkgs.lib.fix (
          self:
          pkgs.callPackage "${nixpkgs}/pkgs/development/libraries/boost/1.81.nix" {
            stdenv = pkgs.llvmPackages_21.libcxxStdenv;

            # Use the right version of boost-build.
            # This has been copied from nixpkgs.
            boost-build = pkgs.boost-build.override { useBoost = self; };
          }
        )).overrideAttrs
          (oldAttrs: {
            # Build only the libraries we're interseted in
            configureFlags = oldAttrs.configureFlags ++ [ "--with-libraries=test" ];
          });

      aws-crt-cpp = (
        pkgs.callPackage "${nixpkgs}/pkgs/by-name/aw/aws-crt-cpp/package.nix" {
          stdenv = stdenv;
        }
      );

      aws-sdk-cpp =
        (pkgs.callPackage "${nixpkgs}/pkgs/by-name/aw/aws-sdk-cpp/package.nix" {
          stdenv = stdenv;

          aws-crt-cpp = aws-crt-cpp;

          # Only build the APIs we're interested in
          apis = [ "s3" ];
        }).overrideAttrs
          (oldAttrs: {
            cmakeFlags = oldAttrs.cmakeFlags ++ [
              "-DENABLE_TESTING=OFF"
              "-DFORCE_CURL=ON"
              "-DENABLE_UNITY_BUILD=OFF"
              "-DENABLE_RTTI=OFF"
              "-DCPP_STANDARD=20"
            ];
          });

      qemuxx =
        pkgs: llvmPackages: name: cflags: suffixes:
        (llvmPackages.stdenv.mkDerivation {
          name = name;

          src = pkgs.fetchFromGitHub {
            owner = "revng";
            repo = "qemu";
            rev = "b3b4301088a914159c88878308937a5c5d382008";
            sha256 = "sha256-4yuBlDXpEs/garWzJ4g300GLbSHHAtbErT+ZyowDSR8=";
          };

          postPatch = ''
            patchShebangs python/scripts/link-embedded-objects

            grep -vF "subdir('fp')" tests/meson.build > tests/meson.build2
            mv tests/meson.build2 tests/meson.build

            # WIP
            grep -vF "_Static_assert" target/i386/cpu.h > target/i386/cpu.h2
            mv target/i386/cpu.h2 target/i386/cpu.h

            grep -vF "ASSERT_CONSTANT" libtcg/libtcg.c > libtcg/libtcg.c2
            mv libtcg/libtcg.c2 libtcg/libtcg.c
          '';

          preBuild = ''
            cd build
          '';

          nativeBuildInputs = with pkgs; [
            (python3.withPackages (python-pkgs: [ python-pkgs.distlib ]))
            # Hooks from the python package are needed to add `$pythonPath` so
            # `python/scripts/mkvenv.py` can detect `meson` otherwise the vendored meson without patches will be used.
            python3Packages.python
            pkg-config
            meson
            ninja
            coreutils-full
            zlib
            llvmPackages.clang
            llvmPackages.llvm
          ];

          buildInputs = with pkgs; [
            glib
          ];

          dontUseMesonConfigure = true;
          enableParallelBuilding = true;

          configureFlags =
            let
              targets = builtins.concatStringsSep "," (
                pkgs.lib.flatten (
                  map (
                    suffix:
                    map (architecture: "${architecture}-${suffix}") [
                      "arm"
                      "aarch64"
                      "i386"
                      "mips"
                      "mipsel"
                      "s390x"
                      "x86_64"
                    ]
                  ) suffixes
                )
              );
            in
            [
              "--disable-plugins"
              "--target-list=${targets}"
              "--disable-werror"
              "--disable-docs"
              "--disable-kvm"
              "--disable-tools"
              "--disable-system"
              "--disable-libnfs"
              "--disable-vde"
              "--disable-gnutls"
              "--disable-cap-ng"
              "--disable-pie"
              "-Dvhost_user=disabled"
              "-Dxkbcommon=disabled"
              "--extra-cflags=-Wno-unused-variable"
              "--extra-cflags=-Wno-unused-function"
              "--extra-cflags=-Wno-unused-result"
              "--extra-cflags=-Wno-unused-but-set-variable"
              (map (argument: "--extra-cflags=${argument}") cflags)
            ];

          preInstall = ''
            mkdir -p $out/include
            mkdir -p $out/lib
          '';
        });

    in
    {
      packages.${system} = {
        yyy = pkgs-2505.clang_16;

        xxx =
          let
            python = pkgs.python3;
            workspace = uv2nix.lib.workspace.loadWorkspace {
              workspaceRoot = ./revng-python-dependencies;
            };
            pythonBase = pkgs.callPackage pyproject-nix.build.packages {
              python = pkgs.python3;
            };
            overlay = workspace.mkPyprojectOverlay {
              sourcePreference = "wheel";
            };
            pythonSet = pythonBase.overrideScope (
              pkgs.lib.composeManyExtensions [
                pyproject-build-systems.overlays.wheel
                overlay
                (
                  final: prev:
                  let
                    inherit (final) resolveBuildSystem;
                    inherit (builtins) mapAttrs;

                    buildSystemOverrides = {
                      grandiso = {
                        setuptools = [ ];
                      };
                      hexdump = {
                        setuptools = [ ];
                      };
                      httptools = {
                        setuptools = [ ];
                      };
                      vivisect-vstruct-wb = {
                        setuptools = [ ];
                      };
                      regex = {
                        setuptools = [ ];
                      };
                      python-idb = {
                        setuptools = [ ];
                      };
                      paginate = {
                        setuptools = [ ];
                      };
                      markupsafe = {
                        setuptools = [ ];
                      };
                    };

                  in
                  mapAttrs (
                    name: spec:
                    prev.${name}.overrideAttrs (old: {
                      nativeBuildInputs = old.nativeBuildInputs ++ resolveBuildSystem spec;
                    })
                  ) buildSystemOverrides
                )
                (self: super: {
                  hexdump = super.hexdump.overrideAttrs (old: {
                    postPatch = ''
                      cd ..
                    '';
                  });
                })
              ]
            );
            venv = pythonSet.mkVirtualEnv "hello-world-env" workspace.deps.default;
          in
          venv;

        # Build our LLVM fork
        llvm = stdenv.mkDerivation {
          name = "llvm";

          src = pkgs.fetchFromGitHub {
            owner = "revng";
            repo = "llvm-project";
            rev = "e3667d437564e0fb1fbf6fb13d9d14ebc1023d90";
            sha256 = "sha256-Z4o+BGgBEkwm42ZB06V8i9itf95itls3aAepyn9tlfg=";
          };

          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            python3
          ];

          cmakeFlags = [
            "-GNinja"

            "-DCMAKE_C_FLAGS=-O2"
            "-DCMAKE_CXX_FLAGS=-O2"
            "-DCMAKE_BUILD_TYPE=Debug"

            "-DCMAKE_INSTALL_BINDIR=libexec"

            "-DLLVM_INSTALL_UTILS=ON"
            "-DLLVM_ENABLE_DUMP=ON"
            "-DLLVM_ENABLE_TERMINFO=OFF"
            "-DCMAKE_CXX_STANDARD=20"
            "-DLLVM_ENABLE_Z3_SOLVER=OFF"
            "-DLLVM_ENABLE_ZLIB=ON"
            "-DLLVM_ENABLE_LIBEDIT=ON"
            "-DLLVM_ENABLE_LIBXML2=OFF"
            "-DLLVM_ENABLE_ZSTD=OFF"

            "-DBUILD_SHARED_LIBS=ON"
            "-DLLVM_ENABLE_PROJECTS=clang;mlir"
            "-DLLVM_TARGETS_TO_BUILD=AArch64;ARM;Mips;SystemZ;X86"
            "-DCMAKE_CXX_FLAGS=-Wno-global-constructors"
          ];

          preConfigure = "cd llvm";

        };
        
        # Build clang to compile QEMU helpers
        clangRelease = stdenv.mkDerivation {
          name = "clang-release";

          src = pkgs.fetchFromGitHub {
            owner = "revng";
            repo = "llvm-project";
            rev = "40999c81da57c2df0e0e808cb5282725e27013e2";
            sha256 = "sha256-+Bl/mLEAXefmq74/4HhhHaGGE0mHc1YdvwPzRaO+wfg=";
          };

          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            python3
          ];

          cmakeFlags = [
            "-GNinja"

            "-DLLVM_INSTALL_UTILS=ON"
            "-DLLVM_ENABLE_DUMP=ON"
            "-DLLVM_ENABLE_TERMINFO=OFF"
            "-DCMAKE_CXX_STANDARD=20"
            "-DLLVM_ENABLE_Z3_SOLVER=OFF"
            "-DLLVM_ENABLE_ZLIB=ON"
            "-DLLVM_ENABLE_LIBEDIT=ON"
            "-DLLVM_ENABLE_LIBXML2=OFF"
            "-DLLVM_ENABLE_ZSTD=OFF"

            "-DBUILD_SHARED_LIBS=ON"
            "-DLLVM_ENABLE_PROJECTS=clang;compiler-rt;clang-tools-extra;lld"
            "-DLLVM_TARGETS_TO_BUILD=X86"
            "-DCOMPILER_RT_INCLUDE_TESTS=OFF"
          ];

          preConfigure = "cd llvm";

        };

        # Build our fork of QEMU
        qemu = qemuxx pkgs pkgs.llvmPackages_21 "qemu" [ "-fPIC" ] [ "linux-user" "libtcg" ];
        qemuHelpers =
          qemuxx pkgs-2505 pkgs-2505.llvmPackages_16 "qemu-helpers"
            [
              "-fPIC"
              "-Wno-gcc-compat"
              "-DGEN_LLVM_HELPERS"
              "-O0"
              "-Xclang"
              "-disable-O0-optnone"
              "-fembed-bitcode"
            ]
            [ "llvm-helpers" ];

        revng-qa = stdenv.mkDerivation {
          name = "revng-qa";

          src = pkgs.fetchurl {
            url = "https://github.com/revng/revng-qa/archive/a49c962.tar.gz";
            sha256 = "sha256-s+cmnktpoHcoSi/8WHi3QDXZtLNpLs60NHsKGweU1Cg=";
          };

          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            (python312.withPackages (
              ps: with ps; [
                jinja2
                pyyaml
              ]
            ))
          ];

          cmakeFlags = [
            "-GNinja"
          ];

        };

        "test/revng-qa" = stdenv.mkDerivation {
          name = "test/revng-qa";

          unpackPhase = "true";

          nativeBuildInputs =
            with pkgs; 
            ([
            gcc
            binutils
            llvm_21
            lld_21
            ]++(import ./crossShell.nix) {
              inherit nixpkgs;
              inherit system;
            })
            ++ ((import ./msvc.nix) { pkgs = pkgs; })
            ++ [
              self.packages.${system}.revng-qa
              ninja
              (python312.withPackages (
                ps: with ps; [
                  jinja2
                  pyyaml
                ]
              ))
              # WIP: this should be pulled by MSVC dep
              pkgs.samba
            ];

          buildPhase = ''
          echo
          '';

          installPhase = ''
            mkdir -p $out
            python3 \
              ${self.packages.${system}.revng-qa}/libexec/revng/test-configure \
              "${self.packages.${system}.revng-qa}/share/revng/test/configuration/revng-qa/"*.yml \
              --install-path "${self.packages.${system}.revng-qa}" \
              --destination . \
              --target-type 'revng-qa\..*'
            export REVNG_OPTIONS="--debug-log=verify"
            grep -v 'shell =' build.ninja > build2.ninja
            mv build2.ninja build.ninja
            ln -s `command -v bash` sh
            export XDG_CACHE_HOME="$PWD/.cache"
            mkdir -p "$XDG_CACHE_HOME/.cache"
            mkdir -p extra-includes/gnu

            i386-winsdk-vc12-cl || true
            i386-winsdk-vc13-cl || true
            i386-winsdk-vc16-cl || true
            i386-winsdk-vc19-cl || true
            x86_64-winsdk-vc19-cl || true
            aarch64-winsdk-vc19-cl || true

            cp -a ${pkgs.glibc.dev}/include/gnu/stubs-64.h extra-includes/gnu/stubs-32.h
            NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -isystem$PWD/extra-includes" NIX_CFLAGS_LINK= PATH="$PWD:$PATH" ninja -v -k0 all
            rm -rf "$XDG_CACHE_HOME"
          '';

        };

        nanobind = stdenv.mkDerivation {
          name = "nanobind";

          src = pkgs.fetchFromGitHub {
            owner = "revng";
            repo = "nanobind";
            fetchSubmodules = true;
            rev = "9987280372f46974236fb5b202f6e085c4347290";
            sha256 = "sha256-PPTKiJaJMyKJ/F+t4DLEyK7fgiafZT+WO8LoHn/zkEE=";
          };

          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            python3
          ];

          preConfigure = "cd standalone";

          cmakeFlags = [
            "-GNinja"
            "-DCMAKE_CXX_STANDARD=20"
            "-DBUILD_SHARED_LIBS=ON"
          ];

        };

        # Use a fake npm project to specify JavaScript dependencies
        revngJavascriptDependencies = pkgs.stdenv.mkDerivation (finalAttrs: {
          nativeBuildInputs = [
            pkgs.nodejs
            pkgs.pnpm.configHook
          ];
          pname = "revng";
          version = "1.0";
          src = ./revng-js-dependencies;
          installPhase = ''
            pwd
            mkdir -p $out/node_modules
            cp -Tar /build/revng-js-dependencies/node_modules $out/node_modules
          '';
          pnpmDeps = pkgs.pnpm.fetchDeps {
            inherit (finalAttrs) pname version src;
            fetcherVersion = 2;
            hash = "sha256-VxFmVePLXkuBR1kaLj+djwdMqn2uh+m5YM0mSIfXOlo=";
          };
        });

        # Build revng
        revng = stdenv.mkDerivation {
          name = "revng";

          src = ./.;

          nativeBuildInputs = with pkgs; [
            aws-sdk-cpp
            boost-test
            cmake
            codespell
            doxygen
            git
            libarchive
            ninja
            nodejs
            zstd
            self.packages.${system}.revngJavascriptDependencies
            makeWrapper
            self.packages.${system}.xxx
            self.packages.${system}.llvm
            self.packages.${system}.qemu
            self.packages.${system}.nanobind
            zlib
          ];

          postPatch = ''patchShebangs --build .'';

          cmakeFlags = [
            "-GNinja"
            "-DCMAKE_CXX_STANDARD=20"
            "-DCMAKE_C_FLAGS=-O2"
            "-DCMAKE_CXX_FLAGS=-O2"
            "-DCMAKE_BUILD_TYPE=Debug"
            "-DLLVM_DIR=${self.packages.${system}.llvm}/lib/cmake/llvm"
            "-DLIBTCG_DIR=${self.packages.${system}.qemu}"
            "-DQEMU_HELPERS_DIR=${self.packages.${system}.qemuHelpers}"
            "-DTEST_REVNG_QA_DIR=${self.packages.${system}."test/revng-qa"}"
            "-DTARGET_CLANG=${self.packages.${system}.yyy}/bin/clang"
          ];

          postFixup = ''
            for PROGRAM in revng revng2 pype; do
                wrapProgram $out/bin/"$PROGRAM" --prefix PYTHONPATH : "${self.packages.${system}.xxx}/${pkgs.python3.sitePackages}"
            done
          '';

         
        };

      };
    };
}
