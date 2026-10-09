{ stdenvNoCC, writeClosure, busybox, firecracker }:
stdenvNoCC.mkDerivation {
  pname = "axvisor-linux-firecracker-host-initramfs-assets";
  version = "1";
  dontUnpack = true;
  installPhase = ''
    mkdir -p $out/bin $out/test $out/nix/store
    cp ${busybox}/bin/busybox $out/bin/busybox
    cp ${firecracker}/bin/firecracker $out/test/firecracker

    while IFS= read -r dep; do
      case "$dep" in
        ${busybox}|${firecracker}) continue ;;
      esac
      cp -r "$dep" $out/nix/store/
    done < ${writeClosure [ busybox firecracker ]}
  '';
}
