{ pkgs, source }:
pkgs.runCommand "zhiyu-dtb"
  {
    nativeBuildInputs = [
      pkgs.stdenv.cc
      pkgs.dtc
    ];
  }
  ''
    mkdir "$out"
    cpp -nostdinc -I ${source.src}/include -undef -x assembler-with-cpp \
      -o board.dts ${../dts/lenovo-zhiyu.dts}
    dtc -I dts -O dtb -o "$out/lenovo-zhiyu.dtb" board.dts
  ''
