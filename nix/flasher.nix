{
  stdenv,
  openssl,
  simulate ? false,
}:
stdenv.mkDerivation {
  name = if simulate then "zhiyu-install-simulator" else "zhiyu-install";
  buildInputs = [ openssl ];
  buildCommand = ''
    mkdir -p "$out/bin"
    $CC -O2 -Wall -Wextra -Werror ${if simulate then "-DZHIYU_FLASH_TEST" else ""} \
      ${./flasher.c} -lcrypto -o "$out/bin/zhiyu-install"
    strip "$out/bin/zhiyu-install"
  '';
}
