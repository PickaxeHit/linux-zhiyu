{ pkgs, sources }:
let
  inherit (pkgs.pkgsMusl) stdenv;
  inherit (pkgs.buildPackages) rustPlatform;
  lockFile = ../keymint/idlc.Cargo.lock;
  mkSource = name: {
    pname = "zhiyu-${name}";
    inherit (sources.${name}) src version;
  };
  cmakeLibrary =
    name: flags: extra:
    stdenv.mkDerivation (
      mkSource name
      // {
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.pkg-config
        ];
        cmakeFlags = [
          "-DCMAKE_INSTALL_LIBDIR=lib"
          "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
          "-DBUILD_SHARED_LIBS=OFF"
        ]
        ++ flags;
      }
      // extra
    );
  idlc = rustPlatform.buildRustPackage (
    mkSource "mink-idl-compiler"
    // {
      cargoLock = { inherit lockFile; };
      postUnpack = ''
        cp ${lockFile} "$sourceRoot/Cargo.lock"
      '';
      cargoBuildFlags = [
        "-p"
        "idlc"
      ];
      cargoTestFlags = [
        "-p"
        "idlc"
      ];
      nativeBuildInputs = [ pkgs.buildPackages.git ];
      postInstall = ''
        test -x "$out/bin/idlc"
      '';
    }
  );
  qcbor = cmakeLibrary "qcbor" [ ] { };
  quic-teec = cmakeLibrary "quic-teec" [ "-DQCBOR_DIR_HINT=${qcbor}" ] { };
  minkipc =
    cmakeLibrary "minkipc"
      (
        [
          "-DQCOMTEE_DIR_HINT=${quic-teec}"
          "-DQCBOR_DIR_HINT=${qcbor}"
          "-DMINKIDLC_BIN_DIR=${idlc}/bin"
        ]
        ++ map (feature: "-DBUILD_${feature}=OFF") [
          "MINKTEEC"
          "PKCS11"
          "RPMB_CLIENT"
          "RPMB_LISTENER"
          "FS_LISTENER"
          "GPFS_LISTENER"
          "TA_AUTOLOAD_LISTENER"
          "TIME_LISTENER"
        ]
      )
      {
        postPatch = ''
          # pthread_t needs an explicit header with musl.
          sed -i '/^#include <qcomtee_object_types.h>/a#include <pthread.h>' libminkadaptor/src/supplicant.h
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p "$out/lib" "$out/src"
          ar rcs "$out/lib/libminkadaptor.a" libminkadaptor/CMakeFiles/minkadaptor.dir/src/*.o
          cp -R ../libminkadaptor ../listeners "$out/src/"
          runHook postInstall
        '';
      };
  openssl = stdenv.mkDerivation (
    mkSource "openssl"
    // {
      nativeBuildInputs = [ pkgs.perl ];
      enableParallelBuilding = true;
      configurePhase = ''
        runHook preConfigure
        patchShebangs Configure util
        perl ./Configure linux-aarch64 --prefix="$out" --libdir=lib --openssldir=/etc/ssl \
          no-shared no-tests no-zlib
        runHook postConfigure
      '';
      buildFlags = [ "build_libs" ];
      installTargets = [ "install_dev" ];
    }
  );
  helpers = stdenv.mkDerivation {
    name = "zhiyu-keymint-helpers";
    nativeBuildInputs = [ pkgs.binutils ];
    disallowedReferences = [
      openssl
      minkipc
      quic-teec
      qcbor
    ];
    buildCommand = ''
      mkdir -p src/keymint src/initramfs-src/src "$out"
      cp ${../keymint/build.sh} src/keymint/build.sh
      cp ${../keymint/stage-initramfs.sh} src/keymint/stage-initramfs.sh
      cp ${../keymint/unlock_metadata.c} src/keymint/unlock_metadata.c
      cp ${../keymint/rpmb_proxy.c} src/keymint/rpmb_proxy.c
      cp ${../keymint/time_main.c} src/keymint/time_main.c
      cp ${../initramfs-src/src/userdata-map.c} src/initramfs-src/src/userdata-map.c
      export KEYMINT_CRYPTO_PREFIX=${openssl} MINK_SRC=${minkipc}/src MINK_LIB=${minkipc}/lib
      export QCOMTEE_LIB=${quic-teec}/lib QCBOR_LIB=${qcbor}/lib KEYMINT_BIN="$PWD/bin"
      bash src/keymint/build.sh
      bash src/keymint/stage-initramfs.sh "$out"
    '';
  };
in
{
  inherit
    idlc
    qcbor
    quic-teec
    minkipc
    ;
  openssl-static = openssl;
  keymint = helpers;
}
