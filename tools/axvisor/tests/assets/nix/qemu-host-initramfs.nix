{ stdenvNoCC, stdenv, lib, writeClosure, busybox, qemu, dtc
, targetArch, peerSource }:
let
  qemuSystemArch = if targetArch == "x86_64" then
    "x86_64"
  else if targetArch == "riscv64" then
    "riscv64"
  else
    throw "unsupported QEMU test architecture: ${targetArch}";
  qemuBase = qemu.override {
    hostCpuOnly = true;
    hostCpuTargets = [ "${qemuSystemArch}-softmmu" ];
    minimal = true;
    pluginsSupport = false;
    uringSupport = false;
  };
  qemuKvm = qemuBase.overrideAttrs (old: {
    buildInputs = old.buildInputs ++ [ dtc ];
    configureFlags = old.configureFlags ++ [
      "--disable-curl"
      "--disable-gnutls"
      "--disable-linux-aio"
      "--disable-linux-io-uring"
    ];
  });
  virtioNetPeer = stdenv.mkDerivation {
    pname = "virtio-net-peer";
    version = "0.1.0";
    src = peerSource;
    dontUnpack = true;
    buildInputs = [ stdenv.cc.libc.static ];
    buildPhase = ''
      ${stdenv.cc.targetPrefix}cc -Wall -Werror -static "$src" -o virtio_net_peer
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp virtio_net_peer $out/bin/
    '';
  };
  x86FirmwareNames = [
    "bios-256k.bin"
    "bios-microvm.bin"
    "linuxboot_dma.bin"
    "linuxboot.bin"
    "kvmvapic.bin"
    "pvh.bin"
  ];
  x86Firmware = stdenvNoCC.mkDerivation {
    pname = "qemu-x86-test-firmware";
    inherit (qemuKvm) version;
    src = qemuKvm.src;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out
      for firmware in ${lib.concatStringsSep " " x86FirmwareNames}; do
        cp pc-bios/$firmware $out/$firmware
      done
    '';
  };
  closure = [ busybox qemuKvm ]
    ++ lib.optionals (targetArch == "x86_64") [ virtioNetPeer x86Firmware ];
in
stdenvNoCC.mkDerivation {
  pname = "axvisor-linux-qemu-host-initramfs-${targetArch}";
  version = "1";
  dontUnpack = true;
  installPhase = ''
    mkdir -p $out/bin $out/test $out/nix/store
    cp ${busybox}/bin/busybox $out/bin/busybox
    cp ${qemuKvm}/bin/qemu-system-${qemuSystemArch} \
      $out/test/qemu-system-${qemuSystemArch}
    ${lib.optionalString (targetArch == "x86_64") ''
      cp ${virtioNetPeer}/bin/virtio_net_peer $out/test/
      for firmware in ${lib.concatStringsSep " " x86FirmwareNames}; do
        cp ${x86Firmware}/$firmware $out/test/$firmware
      done
    ''}

    while IFS= read -r dep; do
      case "$dep" in
        ${lib.concatStringsSep "|" closure}) continue ;;
      esac
      cp -r "$dep" $out/nix/store/
    done < ${writeClosure closure}
  '';
}
