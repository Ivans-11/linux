{ target ? "riscv64" }:
let
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/c0bebd16e69e631ac6e52d6eb439daba28ac50cd.tar.gz";
    sha256 = "1fbhkqm8cnsxszw4d4g0402vwsi75yazxkpfx3rdvln4n6s68saf";
  };
  crossSystem = if target == "riscv64" then
    "riscv64-unknown-linux-gnu"
  else if target == "x86_64" then
    "x86_64-unknown-linux-gnu"
  else
    throw "unsupported target: ${target}";
in import nixpkgs {
  inherit crossSystem;
  config = { };
  overlays = [ ];
}
