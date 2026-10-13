# hecate-greetd: the Rust supervisor plus the login screen's QML, installed next to a copy of
# the hecate shell (end4-pC) so the greeter runs the shell's own lock screen code.
{
  lib,
  stdenvNoCC,
  rustPlatform,
  makeWrapper,
  # The shell to show; its `qs` wrapper must have hecate on PATH (the NixOS module does that).
  hecate-shell,
  hecate,
}:
let
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../src
    ];
  };
  bin = rustPlatform.buildRustPackage {
    pname = "hecate-greetd-bin";
    inherit version src;
    cargoLock.lockFile = ../Cargo.lock;
    meta.mainProgram = "hecate-greetd";
  };
in
stdenvNoCC.mkDerivation {
  pname = "hecate-greetd";
  inherit version;
  src = ../qml;

  nativeBuildInputs = [ makeWrapper ];
  # Same as the shell package: its Python scripts have shebangs patchShebangs rejects.
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall

    share=$out/share/hecate-greetd
    mkdir -p $share $out/bin

    # The shell, plus the greeter beside shell.qml: QuickShell takes the root file's directory
    # as the `qs` import root, so `qs.modules.ii.lock` and friends are the shell's.
    cp -r ${hecate-shell}/${hecate-shell.config} $share/shell
    chmod -R u+w $share/shell
    cp greeter.qml $share/shell/greeter.qml
    cp -r modules/greeter $share/shell/modules/greeter

    # Kept apart from the shell, so it doesn't depend on any of it.
    mkdir -p $share/fallback
    cp greeter-fallback.qml $share/fallback/greeter-fallback.qml

    makeWrapper ${bin}/bin/hecate-greetd $out/bin/hecate-greetd \
      --set-default HECATE_GREETD_QML $share/shell/greeter.qml \
      --set-default HECATE_GREETD_FALLBACK_QML $share/fallback/greeter-fallback.qml \
      --set-default HECATE_GREETD_QS ${hecate-shell}/bin/qs \
      --set-default HECATE_GREETD_HECATE ${lib.getExe hecate}

    runHook postInstall
  '';

  passthru.unwrapped = bin;

  meta = {
    description = "greetd greeter for hecate: the shell's lock screen with the look of whoever logs in";
    homepage = "https://github.com/Kex1016/hecate-greetd";
    license = lib.licenses.gpl3Plus;
    mainProgram = "hecate-greetd";
    platforms = lib.platforms.linux;
  };
}
