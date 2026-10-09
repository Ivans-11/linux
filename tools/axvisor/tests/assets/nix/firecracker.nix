{ stdenvNoCC, fetchurl, gnutar, gzip, targetArch }:
let
  releaseArch = if targetArch == "aarch64" then "aarch64"
    else throw "unsupported Firecracker target: ${targetArch}";
  archive = fetchurl {
    url = "https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.0/firecracker-v1.16.0-${releaseArch}.tgz";
    hash = "sha256-UxxxPNvDfUuLwlM9hRqrwCZwlq+hdoCGo3Zyq7Zo79c=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "firecracker-${releaseArch}";
  version = "1.16.0";
  src = archive;
  nativeBuildInputs = [ gnutar gzip ];
  dontUnpack = true;
  installPhase = ''
    mkdir -p $out/bin
    tar -xzf $src
    cp release-v1.16.0-${releaseArch}/firecracker-v1.16.0-${releaseArch} $out/bin/firecracker
    chmod 0755 $out/bin/firecracker
  '';
}
