{ lib, rustPlatform, fetchFromGitHub, makeWrapper, zig }:

rustPlatform.buildRustPackage rec {
  pname = "cargo-zigbuild";
  version = "0.18.3";

  src = fetchFromGitHub {
    owner = "messense";
    repo = pname;
    rev = "8a76c1dbb0c6c704af599652d99545fde2ba6719";
    hash = "sha256-+/KPa+0AQZrww+ua70B3luzYywivFINTowBsNH7doQs=";
  };

  cargoHash = "sha256-wQyD6hP6yDIEP+utr8Gcd9I1h/E750pFP1/03niR6oI=";

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/cargo-zigbuild \
      --prefix PATH : ${zig}/bin
  '';

  meta = with lib; {
    description = "A tool to compile Cargo projects with zig as the linker";
    homepage = "https://github.com/messense/cargo-zigbuild";
    changelog = "https://github.com/messense/cargo-zigbuild/releases/tag/v${version}";
    license = licenses.mit;
    maintainers = with maintainers; [ figsoda ];
  };
}
