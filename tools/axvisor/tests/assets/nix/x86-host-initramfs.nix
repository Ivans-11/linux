{ stdenvNoCC, stdenv, writeClosure, busybox, fetchurl, gnutar, gzip }:
let
  firecrackerArchive = fetchurl {
    url = "https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.0/firecracker-v1.16.0-x86_64.tgz";
    hash = "sha256-vQTiaVLU4VgIV3jGIwoLOD0mGcMZGC4n6qnWGiEuktY=";
  };
  firecracker = stdenvNoCC.mkDerivation {
    pname = "firecracker-x86_64";
    version = "1.16.0";
    src = firecrackerArchive;
    nativeBuildInputs = [ gnutar gzip ];
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      tar -xzf $src
      cp release-v1.16.0-x86_64/firecracker-v1.16.0-x86_64 $out/bin/firecracker
      chmod 0755 $out/bin/firecracker
    '';
  };
  runsc = stdenvNoCC.mkDerivation {
    pname = "runsc";
    version = "20260727.0";
    src = fetchurl {
      url = "https://storage.googleapis.com/gvisor/releases/release/20260727.0/x86_64/runsc";
      hash = "sha256-bsRoCKIslLfqaN2VIegxtExp4NMmeizIYvmmrikM7pE=";
    };
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      cp $src $out/bin/runsc
      chmod 0755 $out/bin/runsc
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "axvisor-linux-host-initramfs-x86_64-assets";
  version = "1";
  dontUnpack = true;
  installPhase = ''
    mkdir -p $out/bin $out/test $out/nix/store
    cp ${busybox}/bin/busybox $out/bin/busybox
    cp ${firecracker}/bin/firecracker $out/test/firecracker
    cp ${runsc}/bin/runsc $out/test/runsc

    # Preserve the runtime closure for the dynamically linked host tools.
    while IFS= read -r dep; do
      case "$dep" in
        ${busybox}|${firecracker}|${runsc}) continue ;;
      esac
      cp -r "$dep" $out/nix/store/
    done < ${writeClosure [ busybox firecracker runsc ]}
  '';
}
