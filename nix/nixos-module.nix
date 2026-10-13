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

  # The greeter's compositor. Each user's monitor layout, keyboard and the like are merged on
  # top at runtime (`user.json`), then whatever `settings` sets.
  baseConfig = lib.recursiveUpdate {
    autostart = [
      [
        (lib.getExe cfg.package)
        "ui"
      ]
    ];
    # Nothing to launch from the login screen: no terminal, launcher or window binds.
    default_binds = false;
    xwayland.enable = false;
    layer_rules = import "${hecate}/nix/shell-layer-rules.nix" ++ [
      {
        match.namespace = "^hecate-greetd$";
        animation = "none";
      }
    ];
    environment.QT_QPA_PLATFORM = "wayland";
  } cfg.settings;

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
      hecate-greetd, a greetd greeter that is the hecate shell's lock screen. It shows the
      wallpaper, colours, widgets, monitor layout and keyboard layout of the user logging in,
      as shared by their shell (Settings → hecate-greetd)
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
        The shell whose lock screen the login screen is. Use the same one your users run, so
        their settings mean the same thing.
      '';
    };

    users = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      defaultText = lib.literalExpression "every user with isNormalUser = true";
      example = [ "majo" ];
      description = ''
        Accounts the login screen offers, in this order. Each gets
        `/var/lib/hecate-greetd/users/<name>`, where their shell shares its look.
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
      example = lib.literalExpression ''{ cursor = { theme = "Bibata-Modern-Classic"; size = 24; }; }'';
      description = ''
        hecate configuration for the login screen's compositor (docs/config.md in wl-hex), under
        each user's own outputs, keyboard, input, cursor, blur and animation settings.
      '';
    };

    fonts = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        rubik
        nerd-fonts.jetbrains-mono
        material-symbols
        twemoji-color-font
      ];
      defaultText = lib.literalExpression "the fonts the shell's Home Manager module installs";
      description = ''
        Fonts for the login screen. The shell's usually come from each user's profile, which
        the greeter can't see, so they're installed system-wide.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        bibata-cursors
        kdePackages.breeze-icons
      ];
      defaultText = lib.literalExpression "[ pkgs.bibata-cursors pkgs.kdePackages.breeze-icons ]";
      description = "Cursor and icon themes your users' settings name, installed system-wide.";
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
    # frame, the same picture, replaces it.
    systemd.services.hecate-greetd-hold-gpu = {
      description = "Keep the GPU open between the login screen and the session";
      wantedBy = [ "greetd.service" ];
      partOf = [ "greetd.service" ];
      script = ''
        # The GPU's driver may load after this starts; the login screen takes longer anyway.
        for _ in $(seq 60); do
          compgen -G '/dev/dri/card*' >/dev/null && break
          sleep 1
        done
        for card in /dev/dri/card*; do
          exec {fd}<"$card"
        done
        exec sleep infinity
      '';
    };

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

    # `hecate-greetd sync` (the shell runs it) and the themes the login screen draws with.
    environment.systemPackages = [ cfg.package ] ++ cfg.extraPackages;
    fonts.packages = cfg.fonts;

    # Unlock the keyring with the login password, as the shell's lock screen does.
    security.pam.services.greetd.enableGnomeKeyring = lib.mkDefault true;
    hardware.graphics.enable = lib.mkDefault true;
    # Power off, reboot and suspend from the login screen.
    security.polkit.enable = lib.mkDefault true;
    services.upower.enable = lib.mkDefault true;
  };
}
