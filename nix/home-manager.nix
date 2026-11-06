{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkDefault
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.programs.aial;

  baseNames = map (n: "base0${lib.toHexString n}") (lib.range 0 15);
  colorType = types.strMatching "#?[0-9a-fA-F]{6}";
  stylixPalette = lib.attrByPath [ "lib" "stylix" "colors" "withHashtag" ] null config;
  hyprlandConfigType = lib.attrByPath [
    "wayland"
    "windowManager"
    "hyprland"
    "configType"
  ] "hyprlang" config;

  # Explicit colors win over Stylix's.
  colors =
    lib.optionalAttrs (cfg.stylix.enable && stylixPalette != null) (
      lib.genAttrs baseNames (n: stylixPalette.${n})
    )
    // lib.filterAttrs (_: color: color != null) cfg.colors;

  # What the panel reads from ~/.config/aial/config.json. Keys left out take the
  # panel's own defaults, which the options below repeat.
  settings = {
    inherit colors;
    inherit (cfg)
      opacity
      cornerRadius
      borderOpacity
      scale
      width
      topOffset
      rows
      placeholder
      history
      ;
    font = {
      inherit (cfg.font) size searchSize;
    }
    // lib.optionalAttrs (cfg.font.family != null) { inherit (cfg.font) family; };
    inherit (cfg) search;
  }
  // lib.optionalAttrs (cfg.palette != null) { palette = toString cfg.palette; };

  command = lib.escapeShellArgs (
    [ (lib.getExe cfg.package) ]
    ++ lib.optionals (cfg.namespace != "aial") [
      "-n"
      cfg.namespace
    ]
  );
  cliphist = lib.getExe pkgs.cliphist;
  binds =
    lib.optional (cfg.hyprlandKeybind != null) "${cfg.hyprlandKeybind}, exec, ${command}"
    ++ lib.optional (cfg.hyprlandClipboardKeybind != null) (
      "${cfg.hyprlandClipboardKeybind}, exec, ${cliphist} list | ${command} | ${cliphist} decode | "
      + lib.getExe' pkgs.wl-clipboard "wl-copy"
    );
in
{
  options.programs.aial = {
    enable = mkEnableOption "aial, a Spotlight-style application launcher for Quickshell";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "aial.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = "The aial package to install.";
    };

    namespace = mkOption {
      type = types.strMatching "[^-].*";
      default = "aial";
      example = "launcher";
      description = ''
        Wayland layer namespace of the panel, which compositor layer rules match.
        Each namespace has its own resident panel. The keybinds and the service
        below use this one.
      '';
    };

    colors = mkOption {
      type = types.submodule {
        options = lib.genAttrs baseNames (
          name:
          mkOption {
            type = types.nullOr colorType;
            default = null;
            example = "#1e1e2e";
            description = "Base16 `${name}` as `#rrggbb`. Null takes it from the palette file.";
          }
        );
      };
      default = { };
      example = lib.literalExpression ''
        {
          base00 = "#1e1e2e"; # panel background
          base05 = "#cdd6f4"; # text
          base0D = "#89b4fa"; # accent
        }
      '';
      description = ''
        Base16 colors. `base00` is the panel background, `base05` the text,
        `base04` secondary text, `base02` the selected row and `base0D` accents.
        A color left null comes from the palette file, then from a built-in
        default, so you can set just the ones you want to change.
      '';
    };

    stylix.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to take the colors from Stylix, for every one not set in
        `programs.aial.colors`. Needs Stylix's Home Manager module. Without
        this, the panel reads the `stylix/palette.json` that Stylix writes to your
        config directory, if there is one.
      '';
    };

    palette = mkOption {
      type = types.nullOr (types.either types.path types.str);
      default = null;
      example = "/home/me/.config/colors/palette.json";
      description = ''
        A JSON file of Base16 colors (`base00` to `base0F`, as `#rrggbb`) to read
        at runtime, instead of `~/.config/stylix/palette.json`. The panel follows
        changes to it. Colors set above win over it.
      '';
    };

    opacity = mkOption {
      type = types.numbers.between 0.0 1.0;
      default = 0.8;
      description = "Opacity of the panel's `base00` background, from 0 to 1.";
    };

    cornerRadius = mkOption {
      type = types.ints.between 0 36;
      default = 22;
      description = "Corner radius of the panel in pixels. Rows and thumbnails inside it stay concentric.";
    };

    borderOpacity = mkOption {
      type = types.numbers.between 0.0 1.0;
      default = 0.2;
      description = ''
        Opacity of the panel's 1 px `base05` border. The default matches the
        border Hyprland draws on floating windows with Stylix. 0 hides it.
      '';
    };

    width = mkOption {
      type = types.ints.between 320 1600;
      default = 680;
      description = "Width of the panel in pixels. It is never wider than the screen less 48 px.";
    };

    scale = mkOption {
      type = types.numbers.between 0.5 2.0;
      default = 1.0;
      description = "Scale applied proportionally to the whole launcher, from 0.5 to 2.";
    };

    topOffset = mkOption {
      type = types.numbers.between 0.0 0.8;
      default = 0.22;
      description = "Distance of the panel from the top of the screen, as a share of the screen's height.";
    };

    rows = mkOption {
      type = types.ints.between 1 12;
      default = 7;
      description = "How many results show at once. A longer list scrolls.";
    };

    placeholder = mkOption {
      type = types.str;
      default = "Search apps";
      description = "Text of the empty search field.";
    };

    font = {
      family = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Inter";
        description = ''
          Font family of the panel, which has to be installed; Qt falls back to the
          system font for one that is not. Null uses the Geist Sans that comes with aial.
        '';
      };

      packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        example = lib.literalExpression "[ pkgs.inter ]";
        description = "Font packages to install for `programs.aial.font.family`, if no other part of your configuration does.";
      };

      size = mkOption {
        type = types.ints.between 8 40;
        default = 15;
        description = "Size of the result names in pixels.";
      };

      searchSize = mkOption {
        type = types.ints.between 10 60;
        default = 24;
        description = "Size of the search field's text in pixels.";
      };
    };

    search = {
      matching = mkOption {
        type = types.enum [
          "normal"
          "regex"
          "glob"
          "fuzzy"
          "prefix"
        ];
        default = "normal";
        description = "How the words you type match, as rofi's `-matching`.";
      };

      normalize = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to ignore diacritics when matching, as rofi's `-normalize-match`.";
      };

      sort = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to sort matches by how well they match, as rofi's `-sort`, instead of by the usual order.";
      };

      sortingMethod = mkOption {
        type = types.enum [
          "normal"
          "fzf"
        ];
        default = "normal";
        description = "How `search.sort` ranks matches, as rofi's `-sorting-method`.";
      };

      matchFields = mkOption {
        type = types.listOf (
          types.enum [
            "name"
            "generic"
            "exec"
            "categories"
            "keywords"
            "comment"
          ]
        );
        default = [
          "name"
          "generic"
          "exec"
          "categories"
          "keywords"
        ];
        description = "The fields of a desktop entry that the words you type are looked for in.";
      };

      preferNameMatch = mkOption {
        type = types.bool;
        default = true;
        description = "Whether apps matching by name come before those that need the other fields.";
      };
    };

    history = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether recently launched apps come first, and each launch is recorded in `~/.cache/applesearch.druncache`.";
      };

      size = mkOption {
        type = types.ints.between 1 1000;
        default = 25;
        description = "How many apps the launch history keeps.";
      };
    };

    service.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to start the panel, hidden, with your graphical session, so it
        is already resident the first time you open it. Without it, the first
        launch of the session starts the panel itself, which takes a moment.
      '';
    };

    hyprlandKeybind = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "SUPER, SPACE";
      description = "A Hyprland `bind` (modifiers, key) that opens and closes the panel. Null adds none.";
    };

    hyprlandClipboardKeybind = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "SUPER, V";
      description = ''
        A Hyprland `bind` (modifiers, key) that picks from your clipboard history
        in the panel and copies the choice. Needs `cliphist` to be storing the
        history, e.g. with `services.cliphist.enable`. Null adds none.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isLinux;
        message = "programs.aial is only supported on Linux.";
      }
      {
        assertion = !cfg.stylix.enable || stylixPalette != null;
        message = "programs.aial.stylix.enable needs Stylix: import its Home Manager module and set stylix.enable = true.";
      }
      {
        # In a Lua config Home Manager passes a bind string to hl.bind as it is,
        # which is not the form hl.bind takes.
        assertion = binds == [ ] || hyprlandConfigType != "lua";
        message = "programs.aial.hyprlandKeybind and hyprlandClipboardKeybind write hyprlang binds. With wayland.windowManager.hyprland.configType = \"lua\", bind the aial command in your own config instead.";
      }
    ];

    home.packages = [ cfg.package ] ++ cfg.font.packages;
    fonts.fontconfig.enable = mkIf (cfg.font.packages != [ ]) (mkDefault true);

    xdg.configFile."aial/config.json".text = builtins.toJSON settings;

    # launch.sh --hidden starts the panel as a daemon and returns, so the unit
    # stays active and --stop ends the daemon with it. Apps start in their own
    # units, which outlive a restart of this one.
    systemd.user.services.aial = mkIf cfg.service.enable {
      Unit = {
        Description = "aial, a Spotlight-style application launcher for Quickshell";
        Documentation = "https://github.com/Kalkaro/aial";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${command} --hidden";
        ExecStop = "${command} --stop";
        Slice = "session.slice";
      };

      Install.WantedBy = [ "graphical-session.target" ];
    };

    wayland.windowManager.hyprland.settings.bind = mkIf (binds != [ ]) (lib.mkAfter binds);
  };
}
