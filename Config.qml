import QtQuick
import Quickshell
import Quickshell.Io

// Settings from $XDG_CONFIG_HOME/aial/config.json, which Home Manager writes from
// programs.aial. Every key is optional. A missing, mistyped or out-of-range one
// falls back to its default, so the panel looks as it did before the file existed.
QtObject {
    id: config

    readonly property string path: Quickshell.env("APPLESEARCH_CONFIG")
        || (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/aial/config.json"
    property var values: ({})

    function section(name) {
        let value = values[name];
        return value !== null && typeof value === "object" && !Array.isArray(value) ? value : ({});
    }
    function number(value, fallback, min, max) {
        return typeof value === "number" && isFinite(value) ? Math.min(max, Math.max(min, value)) : fallback;
    }
    function integer(value, fallback, min, max) { return Math.round(number(value, fallback, min, max)); }
    function str(value, fallback) { return typeof value === "string" ? value : fallback; }
    function flag(value, fallback) { return typeof value === "boolean" ? value : fallback; }
    function choice(value, fallback, options) { return options.indexOf(value) >= 0 ? value : fallback; }
    // Fields to search, as a list or as rofi's comma-separated spelling.
    function fields(value, fallback) {
        let names = typeof value === "string" ? value.split(",") : Array.isArray(value) ? value : [];
        names = names.filter(name => typeof name === "string"
                             && ["name", "generic", "exec", "categories", "keywords", "comment"].indexOf(name.trim()) >= 0)
                     .map(name => name.trim());
        return names.length ? names.join(",") : fallback;
    }

    // Base16 colors that win over the palette file, and the palette file to use.
    readonly property var colors: section("colors")
    readonly property string palette: str(values.palette, "")

    // The card's fill, 0 to 1; the corner radius in pixels; the 1 px border's opacity.
    readonly property real opacity: number(values.opacity, 0.8, 0, 1)
    readonly property int cornerRadius: integer(values.cornerRadius, 22, 0, 36)
    readonly property real borderOpacity: number(values.borderOpacity, 0.2, 0, 1)

    // The panel's width in pixels, its distance from the top as a share of the screen's
    // height, and how many results show before the list scrolls.
    readonly property real scale: number(values.scale, 1, 0.5, 2)
    readonly property int width: integer(values.width, 680, 320, 1600)
    readonly property real topOffset: number(values.topOffset, 0.22, 0, 0.8)
    readonly property int rows: integer(values.rows, 7, 1, 12)
    readonly property string placeholder: str(values.placeholder, "Search apps")

    // An empty family keeps the bundled Geist.
    readonly property string fontFamily: str(section("font").family, "")
    readonly property int fontSize: integer(section("font").size, 15, 8, 40)
    readonly property int searchFontSize: integer(section("font").searchSize, 24, 10, 60)

    // Passed to rofi-search.js; the defaults are wave-launcher's.
    readonly property var searchOptions: ({
        matchingMethod: choice(section("search").matching, "normal", ["normal", "regex", "glob", "fuzzy", "prefix"]),
        normalizeMatch: flag(section("search").normalize, false),
        sort: flag(section("search").sort, false),
        sortingMethod: choice(section("search").sortingMethod, "normal", ["normal", "fzf"]),
        matchFieldsSpec: fields(section("search").matchFields, "name,generic,exec,categories,keywords"),
        preferNameMatch: flag(section("search").preferNameMatch, true)
    })

    // Launches recorded in rofi's drun history, which puts recent apps first.
    readonly property bool historyEnabled: flag(section("history").enable, true)
    readonly property int historySize: integer(section("history").size, 25, 1, 1000)

    // The text last parsed, so reading an unchanged file again leaves the settings alone.
    property string loaded: ""

    function load(text) {
        if (text === loaded)
            return;
        loaded = text;
        try {
            let parsed = JSON.parse(text);
            if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed))
                values = parsed;
        } catch (error) {
            // Retain the last valid settings during partial/invalid file writes.
        }
    }

    function refresh() { configFile.reload(); }

    property FileView configFile: FileView {
        path: config.path
        watchChanges: true
        blockLoading: true
        printErrors: false
        onLoaded: config.load(text())
        onFileChanged: reload()
    }

    Component.onCompleted: load(configFile.text())
}
