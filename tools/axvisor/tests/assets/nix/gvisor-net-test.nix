{ stdenv, source }:

stdenv.mkDerivation {
  pname = "gvisor-net-test";
  version = "1";
  dontUnpack = true;

  buildPhase = ''
    $CC -O2 -Wall -Wextra -Werror -static ${source} -o gvisor_net_test
  '';

  installPhase = ''
    mkdir -p $out
    cp gvisor_net_test $out/gvisor_net_test
  '';
}
