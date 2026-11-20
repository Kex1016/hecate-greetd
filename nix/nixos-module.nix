# NixOS module: services.hecate-greetd
{ self, hecate }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hecate-greetd;
  system = pkgs.stdenv.hostPlatform.system;
  dm = config.services.displayManager;

  hecatePackage = cfg.hecatePackage;
  # The shell's `qs` with hecate on PATH, like the Home Manager module's finalPackage.
  shellPackage = cfg.shellPackage.override { extraPackages = [ hecatePackage ]; };

  users =
    if cfg.users != null then
      cfg.users
    else
      lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);

  # Where the login screen's hecate writes down its blobs when it exits, and the session's
  # hecate carries on from (its `background.blobs.resume`, which hecate's Home Manager module
  # points here). Under /run: it only means something until the next frame.
  blobsFile = "/run/hecate-greetd/blobs.json";

  # The haiiro faces with their fontconfig fallback order, from the same hecate as the shell.
  haiiroFonts =
    hecate.packages.${system}.haiiro-fonts or (pkgs.callPackage "${hecate}/nix/fonts.nix" { });

  # The greeter's compositor: `settings` over the haiiro look, and each user's keyboard and
  # monitor layout merged on top at runtime (`user.json`). The background is hecate's own
  # blobs, for everyone and always moving: that part is not `settings`' to change.
  baseConfig =
    lib.recursiveUpdate
      (lib.recursiveUpdate {
        autostart = [
          [
            (lib.getExe cfg.package)
            "ui"
          ]
        ];
        # Nothing to launch from the login screen: no terminal, launcher or window binds.
        default_binds = false;
        xwayland.enable = false;
        general.background_color = "#191724";
        blur.enable = false;
        # The login screen pixelates its own parts in and out; its surface is just there.
        layer_rules = [
          {
            match.namespace = "^hecate-greetd$";
            animation = "none";
          }
        ];
        environment.QT_QPA_PLATFORM = "wayland";
      } cfg.settings)
      {
        background.blobs = {
          enable = true;
          still = false;
          save = blobsFile;
        };
        # No picture of a desktop before or after the login screen: the blobs are what the
        # session's first frame carries on from.
        splash.enable = false;
      };

  shellSettingsFile = (pkgs.formats.json { }).generate "hecate-greetd-shell.json" cfg.shellSettings;

  # One command for a login that still shows a black frame: what the kernel did in between.
  handoverCapture = pkgs.writeShellApplication {
    name = "hecate-handover-capture";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      gnugrep
      systemd
    ];
    text = builtins.readFile ./handover-capture.sh;
  };

  baseConfigFile =
    pkgs.runCommand "hecate-greetd-compositor.json"
      {
        config = builtins.toJSON baseConfig;
        passAsFile = [ "config" ];
      }
      ''
        cp "$configPath" config.json
        ${lib.getExe hecatePackage} validate config.json
        cp config.json $out
      '';

  session = pkgs.writeShellScript "hecate-greetd-session" ''
    export HECATE_GREETD_BASE_CONFIG=${baseConfigFile}
    export HECATE_GREETD_SESSION_DIRS=${dm.sessionData.desktops}/share/wayland-sessions
    export HECATE_GREETD_USERS=${lib.escapeShellArg (lib.concatStringsSep "," users)}
    export HECATE_GREETD_SHELL_CONFIG=${shellSettingsFile}
    ${lib.optionalString (
      cfg.defaultUser != null
    ) "export HECATE_GREETD_DEFAULT_USER=${lib.escapeShellArg cfg.defaultUser}"}
    ${lib.optionalString (
      cfg.defaultSession != null
    ) "export HECATE_GREETD_DEFAULT_SESSION=${lib.escapeShellArg cfg.defaultSession}"}
    exec ${lib.getExe cfg.package} session
  '';
in
{
  options.services.hecate-greetd = {
    enable = lib.mkEnableOption ''
      hecate-greetd, a greetd greeter built from the hecate shell's parts, over hecate's blob
      background. It looks the same for everyone and takes the monitor layout and keyboard
      layout of the user logging in, as shared by their shell (Settings → hecate-greetd)
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.hecate-greetd.override {
        hecate = hecatePackage;
        hecate-shell = shellPackage;
      };
      defaultText = lib.literalExpression "hecate-greetd built against hecatePackage and shellPackage";
      description = "The hecate-greetd package.";
    };

    hecatePackage = lib.mkOption {
      type = lib.types.package;
      default =
        if config.programs ? hecate then
          config.programs.hecate.package
        else
          hecate.packages.${system}.hecate;
      defaultText = lib.literalExpression "config.programs.hecate.package";
      description = "The compositor the login screen runs in.";
    };

    shellPackage = lib.mkOption {
      type = lib.types.package;
      default = hecate.packages.${system}.hecate-shell;
      defaultText = lib.literalExpression "inputs.hecate.packages.\${system}.hecate-shell";
      description = ''
        The shell whose parts the login screen is built from. Use the same one your users run,
        so both look the same.
      '';
    };

    users = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      defaultText = lib.literalExpression "every user with isNormalUser = true";
      example = [ "majo" ];
      description = ''
        Accounts the login screen offers, in this order. Each gets
        `/var/lib/hecate-greetd/users/<name>`, where their shell shares their keyboard and
        monitor layout.
      '';
    };

    defaultUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Selected on the first start. After that, the last user to log in is.";
    };

    defaultSession = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = dm.defaultSession;
      defaultText = lib.literalExpression "config.services.displayManager.defaultSession";
      example = "hecate";
      description = ''
        Session (desktop file name in wayland-sessions) for users who haven't picked one.
        `hecate` when null and there is one.
      '';
    };

    settings = lib.mkOption {
      type = (pkgs.formats.json { }).type;
      default = { };
      example = lib.literalExpression ''{ cursor = { theme = "haiiro"; size = 24; }; }'';
      description = ''
        hecate configuration for the login screen's compositor (docs/config.md in hecate), under
        each user's own outputs, keyboard, input and cursor settings. The background is not set
        here: it is hecate's blobs (`background.blobs`), always on and always moving.
      '';
    };

    shellSettings = lib.mkOption {
      type = (pkgs.formats.json { }).type;
      default = { };
      example = lib.literalExpression ''{ time.format = "h:mm AP"; }'';
      description = ''
        Settings of the bundled shell for the login screen, as in a user's
        `~/.config/illogical-impulse/config.json`. The login screen is the same for every
        user, so nothing of theirs is read: what it shows (the clock's format, say) is set
        here.
      '';
    };

    fonts = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ haiiroFonts ];
      defaultText = lib.literalExpression "[ inputs.hecate.packages.\${system}.haiiro-fonts ]";
      description = ''
        Fonts for the login screen, installed system-wide with whatever fontconfig files they
        carry: the greeter has no home to get them from. The default is the haiiro set (IBM
        VGA 8x16, Jacquard 24 and GNU Unifont as the fallback for glyphs those lack), whose
        fontconfig file makes that fallback order hold for every program.
      '';
    };

    hideConsole = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Keep the text console off tty1, where greetd runs. greetd switches the terminal to text
        mode before starting a session, and the console would flash up between the login
        screen and the session. Boot messages, `boot.shell_on_fail` and the emergency shell go
        to tty2 instead (Ctrl+Alt+F2); tty2 and up keep their consoles.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.bibata-cursors ]";
      description = ''
        Cursor themes your users' settings (or `settings.cursor`) name, installed system-wide.
        Without the theme hecate draws its built-in pointer.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(dm.sddm.enable or false) && !(config.services.displayManager.gdm.enable or false);
        message = "services.hecate-greetd replaces the display manager: turn off SDDM / GDM.";
      }
    ];

    services.greetd = {
      enable = true;
      settings = {
        default_session = {
          command = "${session}";
          user = "greeter";
        };
        initial_session = lib.mkIf dm.autoLogin.enable {
          user = dm.autoLogin.user;
          command = lib.getExe hecatePackage;
        };
      };
    };

    # Between the login screen's hecate exiting and the session's starting nothing has the GPU
    # open, and the kernel would put the text console back on screen. Holding it open keeps
    # the login screen's last frame up (hecate leaves it there) until the session's first
    # frame, the same blobs a moment on, replaces it.
    #
    # Through the render node: the kernel counts it as an open of the device (no console
    # restore while it's held), but a render node can never be DRM master. The first open of
    # a card node *becomes* master when there is none, and this starts early in the boot:
    # holding the card node before plymouth opened it left plymouth without the screen and
    # its quit hanging, and greetd, ordered after it, never started.
    systemd.services.hecate-greetd-hold-gpu = {
      description = "Keep the GPU open between the login screen and the session";
      wantedBy = [ "greetd.service" ];
      partOf = [ "greetd.service" ];
      script = ''
        # The GPU's driver may load after this starts; the login screen takes longer anyway.
        # (A plain glob test: the unit's bash has no programmable completion, so no compgen.)
        for _ in $(seq 60); do
          set -- /dev/dri/renderD*
          [ -e "$1" ] && break
          sleep 1
        done
        for node in /dev/dri/renderD*; do
          [ -e "$node" ] || continue
          exec {fd}<"$node"
        done
        exec sleep infinity
      '';
    };

    boot.kernelParams = lib.mkIf cfg.hideConsole [
      "fbcon=vc:2-63"
      "console=tty2"
    ];

    users.users.greeter = {
      home = "/var/lib/hecate-greetd/greeter";
      createHome = true;
    };

    # Users' exports: theirs to write, the greeter group's to read (setgid keeps the group).
    systemd.tmpfiles.settings."10-hecate-greetd" = {
      "/var/lib/hecate-greetd".d = {
        mode = "0755";
        user = "root";
        group = "root";
      };
      "/var/lib/hecate-greetd/users".d = {
        mode = "0755";
        user = "root";
        group = "root";
      };
      "/var/lib/hecate-greetd/greeter".d = {
        mode = "0700";
        user = "greeter";
        group = "greeter";
      };
      # The login screen's hecate writes its blobs here; whoever logs in reads them.
      ${dirOf blobsFile}.d = {
        mode = "0755";
        user = "greeter";
        group = "greeter";
      };
    }
    // lib.genAttrs' users (
      name:
      lib.nameValuePair "/var/lib/hecate-greetd/users/${name}" {
        d = {
          mode = "2750";
          user = name;
          group = "greeter";
        };
      }
    );

    # `hecate-greetd sync` (the shell runs it), `hecate-handover-capture` and the themes the
    # login screen draws with.
    environment.systemPackages = [
      cfg.package
      handoverCapture
    ]
    ++ cfg.extraPackages;
    fonts.packages = cfg.fonts;
    # Only their etc/fonts is taken from these: the haiiro set's fallback order.
    fonts.fontconfig.confPackages = cfg.fonts;

    # Unlock the keyring with the login password, as the shell's lock screen does.
    security.pam.services.greetd.enableGnomeKeyring = lib.mkDefault true;
    hardware.graphics.enable = lib.mkDefault true;
    # Power off, reboot and suspend from the login screen.
    security.polkit.enable = lib.mkDefault true;
    services.upower.enable = lib.mkDefault true;
  };
}
