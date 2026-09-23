{ target ? "riscv64" }:
let
  pkgs = import ./sources.nix { inherit target; };
  lkvm = pkgs.callPackage ./lkvm.nix { };
  x86HostInitramfs = pkgs.callPackage ./x86-host-initramfs.nix { };
  gvisorNetTestX86_64 = pkgs.pkgsStatic.callPackage ./gvisor-net-test.nix {
    source = builtins.path {
      path = ../../programs/gvisor_net_test.c;
      name = "gvisor-net-test.c";
    };
  };
  qemuHostInitramfs = pkgs.callPackage ./qemu-host-initramfs.nix {
    targetArch = target;
    peerSource = builtins.path {
      path = ../../programs/virtio_net_peer.c;
      name = "virtio_net_peer.c";
    };
  };
in {
  hostInitramfs = pkgs.callPackage ./host-initramfs.nix {
    inherit lkvm;
    busybox = pkgs.busybox;
  };
  hostInitramfsX86_64 = x86HostInitramfs;
  hostInitramfsQemu = qemuHostInitramfs;
  inherit gvisorNetTestX86_64;
}
