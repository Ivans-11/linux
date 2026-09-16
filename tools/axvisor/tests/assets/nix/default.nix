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
in {
  hostInitramfs = pkgs.callPackage ./host-initramfs.nix {
    inherit lkvm;
    busybox = pkgs.busybox;
  };
  hostInitramfsX86_64 = x86HostInitramfs;
  inherit gvisorNetTestX86_64;
}
