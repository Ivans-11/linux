{ stdenvNoCC, writeClosure, busybox, lkvm }:
stdenvNoCC.mkDerivation {
  pname = "axvisor-linux-host-initramfs-assets";
  version = "1";

  dontUnpack = true;
  installPhase = ''
    mkdir -p $out/bin $out/test $out/nix/store
    cp ${busybox}/bin/busybox $out/bin/busybox
    cp ${lkvm}/bin/lkvm $out/test/lkvm

    # Keep the complete runtime closure alongside the binaries so dynamic
    # lkvm remains reproducible on a clean host.
    while IFS= read -r dep; do
      case "$dep" in
        ${busybox}|${lkvm}) continue ;;
      esac
      cp -r "$dep" $out/nix/store/
    done < ${writeClosure [ busybox lkvm ]}
  '';
}
