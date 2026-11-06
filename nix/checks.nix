{ self, pkgs }:
let
  inherit (pkgs) lib;

  system = pkgs.stdenv.hostPlatform.system;

  # The module alone, against stand-ins for the Home Manager options it sets.
  evaluate =
    module:
    (lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        (import ./home-manager.nix { inherit self; })
        (
          { lib, ... }:
          {
            options = {
              assertions = lib.mkOption {
                type = lib.types.listOf lib.types.raw;
                default = [ ];
              };
              lib = lib.mkOption {
                type = lib.types.attrsOf lib.types.raw;
                default = { };
              };
              home.packages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [ ];
              };
              fonts.fontconfig.enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
              xdg.configFile = lib.mkOption {
                type = lib.types.attrsOf (
                  lib.types.submodule {
                    options.text = lib.mkOption { type = lib.types.str; };
                  }
                );
                default = { };
              };
              systemd.user.services = lib.mkOption {
                type = lib.types.attrsOf lib.types.raw;
                default = { };
              };
              wayland.windowManager.hyprland = {
                configType = lib.mkOption {
                  type = lib.types.enum [
                    "hyprlang"
                    "lua"
                  ];
                  default = "hyprlang";
                };
                settings.bind = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
              };
            };
          }
        )
        module
      ];
    }).config;

  configOf = evaluated: builtins.fromJSON evaluated.xdg.configFile."aial/config.json".text;
  exe = lib.getExe self.packages.${system}.default;

  plain = evaluate { programs.aial.enable = true; };
  customized = evaluate {
    programs.aial = {
      enable = true;
      namespace = "launcher";
      colors = {
        base00 = "#112233";
        base0D = "445566";
      };
      palette = "/etc/palette.json";
      opacity = 0.5;
      cornerRadius = 12;
      scale = 0.75;
      rows = 5;
      placeholder = "Find";
      font = {
        family = "Inter";
        size = 16;
      };
      search = {
        matching = "fuzzy";
        matchFields = [
          "name"
          "exec"
        ];
      };
      history.enable = false;
      service.enable = false;
      hyprlandKeybind = "SUPER, SPACE";
      hyprlandClipboardKeybind = "SUPER, V";
    };
  };
  withStylix = evaluate {
    lib.stylix.colors.withHashtag = lib.genAttrs (map (n: "base0${lib.toHexString n}") (
      lib.range 0 15
    )) (name: "#0000${lib.substring 4 2 name}");
    programs.aial = {
      enable = true;
      stylix.enable = true;
      colors.base05 = "#ffffff";
    };
  };
  withoutStylix = evaluate {
    programs.aial = {
      enable = true;
      stylix.enable = true;
    };
  };
  lua = evaluate {
    wayland.windowManager.hyprland.configType = "lua";
    programs.aial = {
      enable = true;
      hyprlandKeybind = "SUPER, SPACE";
    };
  };
  luaWithoutBinds = evaluate {
    wayland.windowManager.hyprland.configType = "lua";
    programs.aial.enable = true;
  };
  off = evaluate { };

  failing = evaluated: lib.filter (a: !a.assertion) evaluated.assertions;

  expectations = [
    # By default the file holds the panel's own defaults, no colors, and a resident panel.
    (lib.assertMsg (
      configOf plain == {
        colors = { };
        opacity = 0.8;
        cornerRadius = 22;
        borderOpacity = 0.2;
        scale = 1.0;
        width = 680;
        topOffset = 0.22;
        rows = 7;
        placeholder = "Search apps";
        font = {
          size = 15;
          searchSize = 24;
        };
        search = {
          matching = "normal";
          normalize = false;
          sort = false;
          sortingMethod = "normal";
          matchFields = [
            "name"
            "generic"
            "exec"
            "categories"
            "keywords"
          ];
          preferNameMatch = true;
        };
        history = {
          enable = true;
          size = 25;
        };
      }
    ) "defaults: ${builtins.toJSON (configOf plain)}")
    (lib.assertMsg (plain.home.packages == [ self.packages.${system}.default ]) "package is installed")
    (lib.assertMsg (
      plain.systemd.user.services.aial.Service.ExecStart == "${exe} --hidden"
    ) "service starts hidden")
    (lib.assertMsg (
      plain.systemd.user.services.aial.Service.ExecStop == "${exe} --stop"
    ) "service stops the panel")
    (lib.assertMsg (
      plain.wayland.windowManager.hyprland.settings.bind == [ ]
    ) "no keybinds unless asked")
    (lib.assertMsg (failing plain == [ ]) "no assertion fails by default")

    # Settings reach the file; colors set without the hash still gain it in the panel.
    (lib.assertMsg (
      (configOf customized) == {
        colors = {
          base00 = "#112233";
          base0D = "445566";
        };
        palette = "/etc/palette.json";
        opacity = 0.5;
        cornerRadius = 12;
        borderOpacity = 0.2;
        scale = 0.75;
        width = 680;
        topOffset = 0.22;
        rows = 5;
        placeholder = "Find";
        font = {
          family = "Inter";
          size = 16;
          searchSize = 24;
        };
        search = {
          matching = "fuzzy";
          normalize = false;
          sort = false;
          sortingMethod = "normal";
          matchFields = [
            "name"
            "exec"
          ];
          preferNameMatch = true;
        };
        history = {
          enable = false;
          size = 25;
        };
      }
    ) "customized: ${builtins.toJSON (configOf customized)}")
    (lib.assertMsg (!(customized.systemd.user.services ? aial)) "the service can be turned off")
    (lib.assertMsg
      (
        customized.wayland.windowManager.hyprland.settings.bind == [
          "SUPER, SPACE, exec, ${exe} -n launcher"
          "SUPER, V, exec, ${lib.getExe pkgs.cliphist} list | ${exe} -n launcher | ${lib.getExe pkgs.cliphist} decode | ${lib.getExe' pkgs.wl-clipboard "wl-copy"}"
        ]
      )
      "keybinds use the namespace: ${builtins.toJSON customized.wayland.windowManager.hyprland.settings.bind}"
    )

    # Hyprland's Lua config takes no hyprlang binds, but is fine without them.
    (lib.assertMsg (builtins.length (failing lua) == 1) "binds with a Lua config fail an assertion")
    (lib.assertMsg (failing luaWithoutBinds == [ ]) "a Lua config is fine without binds")

    # Stylix fills every color that is not set by hand.
    (lib.assertMsg (
      let
        colors = (configOf withStylix).colors;
      in
      colors.base00 == "#000000" && colors.base0A == "#00000A" && colors.base05 == "#ffffff"
    ) "stylix colors: ${builtins.toJSON (configOf withStylix).colors}")
    (lib.assertMsg (
      builtins.length (failing withoutStylix) == 1
    ) "stylix.enable without Stylix fails an assertion")

    # Nothing is installed or written until the program is enabled.
    (lib.assertMsg (
      off.home.packages == [ ] && off.xdg.configFile == { } && !(off.systemd.user.services ? aial)
    ) "disabled by default")
  ];
in
{
  package = self.packages.${system}.default;

  module = builtins.deepSeq expectations (pkgs.runCommand "aial-module" { } "touch $out");

  format =
    pkgs.runCommand "aial-format"
      {
        nativeBuildInputs = [ pkgs.nixfmt ];
        src = lib.fileset.toSource {
          root = ../.;
          fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ../.;
        };
      }
      ''
        cd $src
        nixfmt --check $(find . -name '*.nix')
        touch $out
      '';

  tests = pkgs.stdenvNoCC.mkDerivation {
    name = "aial-tests";
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../tests
        ../launch.sh
        ../rofi-search.js
        ../shell.qml
        ../Config.qml
        ../Spring.qml
        ../Theme.qml
        ../fonts
      ];
    };
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      util-linux
      nodejs
      python3
    ];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      runHook preBuild
      patchShebangs launch.sh
      node --test tests/test_rofi_search.js
      python3 -m unittest discover -s tests -v
      runHook postBuild
    '';
    installPhase = "touch $out";
  };
}
