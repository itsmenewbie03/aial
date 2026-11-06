// Qt otherwise advances animations by the primary screen's frame interval,
// which runs them too fast and unevenly on a higher refresh rate monitor.
//@ pragma Env QSG_USE_SIMPLE_ANIMATION_DRIVER=1
// Qt's default subpixel text antialiasing leaves colour fringes on the text.
//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray
import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import "rofi-search.js" as RofiSearch

ShellRoot {
    id: root

    Config { id: config }
    Theme { id: theme; overrides: config.colors; palettePath: config.palette }
    FontLoader { id: bundledFont; source: "fonts/Geist.ttf" }
    // The bundled Geist unless config.json names another family.
    readonly property string fontFamily: config.fontFamily || bundledFont.name

    property bool opened: Quickshell.env("APPLESEARCH_HIDDEN") !== "1"
    property var results: []
    property int selected: 0
    property bool selectionExplicit: false
    property var hoverPosition: null
    // Lines piped to launch.sh, which waits at menuResult for the one picked, dmenu style.
    property var menuEntries: []
    property string menuResult: ""
    readonly property bool menuMode: menuEntries.length > 0
    // Typing ! first turns the field into a shell command to run, not an application to find.
    // The ! itself is not kept in the field; Backspace in the empty field leaves the mode.
    property bool shellMode: false
    // A menu of copied images opens transparent until the thumbnails in view have loaded, so they
    // are in place when the card appears instead of replacing their icons in front of the user.
    property bool menuHeld: false
    property real menuHeldSince: 0
    // A menu replacing the one on screen waits here while its thumbnails load, then swaps in whole.
    property var pendingMenu: null
    property real pendingSince: 0
    // The entries whose thumbnails are being loaded for it.
    property var preloadEntries: []
    property var targetScreen: Quickshell.screens[0]
    // Hyprland reports its monitors a few milliseconds after the panel starts, so a cold
    // start does not know the focused one yet. The panel stays unmapped until a screen is
    // chosen, which waits for Hyprland for at most 300 ms, instead of opening on the first.
    property bool screenPending: true
    readonly property string namespace: Quickshell.env("APPLESEARCH_NAMESPACE") || "aial"
    readonly property string directory: Quickshell.env("APPLESEARCH_SOURCE_DIR") || decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))
    // A menu has no search field, so its lines start at the top of the card.
    readonly property int searchHeight: menuMode ? 0 : 72
    // The rows set in the config fit; a longer list scrolls. Without results only the search row shows.
    readonly property int resultsHeight: results.length ? Math.min(results.length, config.rows) * 62 + 16 : 0
    readonly property bool isHyprland: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE").length > 0
    // Result names stay dimmer until selected, then move toward white (black on light palettes).
    readonly property color titleColor: Qt.alpha(theme.base05, 0.8)
    readonly property color selectedTitleColor: Qt.tint(theme.base05, theme.dark ? "#80ffffff" : "#80000000")
    onOpenedChanged: hoverPosition = null

    // Apps are searched as in wave-launcher: the same entries, its port of
    // rofi's drun matching and order, and its default settings.
    property int appReloadCounter: 0
    Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            root.appReloadCounter++;
        }
    }
    readonly property var applications: {
        root.appReloadCounter;
        let entries = Array.from(DesktopEntries.applications.values);
        return entries.filter((entry, index, all) =>
            !entry.noDisplay && index === all.findIndex(candidate => candidate.id === entry.id));
    }
    readonly property var preparedApplications: applications.map(entry => RofiSearch.prepareApplication(entry))
    // Apps installed or removed while a query is open update its results.
    onPreparedApplicationsChanged: if (!menuMode) matchApps()

    // Launches are recorded in rofi's drun history format, which lists recently
    // launched apps first. Panels in other namespaces share the file.
    property var drunHistory: ({})
    FileView {
        id: drunCache
        path: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/applesearch.druncache"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.drunHistory = RofiSearch.parseDrunHistory(text())
        onFileChanged: reload()
    }

    function searchApplications(text) {
        if (text.trim().length === 0)
            return [];
        // rofi-search.js still lets the history order name matches, so it gets none when it is off.
        return RofiSearch.search(text, preparedApplications, Object.assign({
            drunHistory: config.historyEnabled ? drunHistory : ({}),
            useDrunHistory: config.historyEnabled
        }, config.searchOptions));
    }

    function matchApps() {
        // A shell command is the field's text, with no result row to repeat it.
        if (shellMode) {
            results = [];
            selected = 0;
            selectionExplicit = false;
            return;
        }
        // A row picked with the keys or pointer stays selected if it is still listed.
        let previous = selectionExplicit && selected >= 0 && selected < results.length ? results[selected].id : "";
        results = searchApplications(input.text).map(entry => ({id: entry.id, title: entry.name, kind: "app",
                                                                 icon: entry.icon, entry: entry}));
        let same = results.findIndex(result => result.id === previous);
        selected = Math.max(0, same);
        selectionExplicit = same >= 0;
    }

    function launch(entry) {
        if (config.historyEnabled) {
            let history = RofiSearch.recordDrunLaunch(drunCache.text(), entry.id, config.historySize);
            drunCache.setText(history);
            drunHistory = RofiSearch.parseDrunHistory(history);
        }
        hidePanel();
        // launch.sh starts the app in its own systemd unit, with the session's
        // environment rather than Quickshell's, and in a terminal if it asks for one.
        let options = entry.runInTerminal ? ["--terminal"] : [];
        if (entry.workingDirectory)
            options.push("--directory", entry.workingDirectory);
        Quickshell.execDetached([directory + "/launch.sh", "--run", ...options, "--", ...Array.from(entry.command)]);
    }

    function runShell(command) {
        hidePanel();
        // Like an app, in its own systemd unit with the session's environment.
        Quickshell.execDetached([directory + "/launch.sh", "--run", "--", "sh", "-c", command]);
    }

    // The screen the panel opens on: the focused monitor's, once Hyprland has told us it.
    function chooseScreen() {
        if (isHyprland && !Hyprland.focusedMonitor) {
            screenPending = true;
            monitorTimer.restart();
            return;
        }
        monitorTimer.stop();
        targetScreen = Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) || Quickshell.screens[0];
        screenPending = false;
    }

    function showPanel() {
        config.refresh();
        theme.refresh();
        if (menuMode) {
            // A search replaces a menu, even one still fading out.
            answerMenu(null);
            answerPending();
            resetPanel();
        }
        if (panel.visible) {
            // Reopening during the close fade reverses it and keeps the query. A
            // launch that closed the panel may have reordered its results.
            matchApps();
        } else {
            chooseScreen();
            shellMode = false;
            input.text = "";
            results = [];
            selected = 0;
            selectionExplicit = false;
            presence.value = 0;
        }
        panel.fade = 1;
        opened = true;
        focusTimer.restart();
    }

    function hidePanel() {
        // Hiding without picking a line cancels a menu.
        answerMenu(null);
        answerPending();
        // Focus returns immediately; the card fades out with its content.
        opened = false;
        menuHeld = false;
        panel.fade = 0;
        grab.active = false;
        focusTimer.stop();
    }

    // Runs once the close animation has hidden the window.
    function resetPanel() {
        menuHeld = false;
        menuEntries = [];
        shellMode = false;
        input.text = "";
        // A menu's text is always empty, so clearing it leaves the lines.
        results = [];
    }

    // A menu has no search: it lists the lines in their order, so clipboard
    // history stays newest first.
    function showMenu(lines, result, images) {
        // The rows are all built at once, so a huge input lists only its first 100 lines.
        let entries = lines.slice(0, 100).map(line => menuEntry(line, images));
        // A newer menu replaces one still waiting to replace the one on screen.
        answerPending();
        if (opened && menuMode && entries.slice(0, config.rows).some(entry => entry.image)) {
            // Its thumbnails are in new files, so the rows would show empty slots while they
            // load again. The menu stays as it is until they have, and the rows change in one step.
            pendingMenu = {entries: entries, result: result};
            preloadEntries = entries.slice(0, config.rows);
            pendingSince = Date.now();
            return;
        }
        openMenu(entries, result);
    }

    function openMenu(entries, result) {
        // A menu replacing one already on screen has nothing to wait for.
        let fresh = !panel.visible;
        // Replaces a search, or a menu still waiting for its answer.
        showPanel();
        shellMode = false;
        input.text = "";
        menuResult = result;
        menuEntries = entries;
        results = menuEntries;
        selected = 0;
        selectionExplicit = false;
        hoverPosition = null;
        menuHeld = fresh && menuEntries.slice(0, config.rows).some(entry => entry.image);
        menuHeldSince = Date.now();
    }

    function applyPendingMenu() {
        let next = pendingMenu;
        // Cleared before opening, which would cancel it, but the thumbnails stay loaded until the rows are built.
        pendingMenu = null;
        openMenu(next.entries, next.result);
        preloadEntries = [];
    }

    // Cancels the menu waiting to replace the one on screen, which its launch.sh is waiting on.
    function answerPending() {
        if (!pendingMenu)
            return;
        let file = menuFile.createObject(root, {path: pendingMenu.result, preload: false});
        file.setText("cancelled\n");
        file.destroy();
        pendingMenu = null;
        preloadEntries = [];
    }

    // Whether the thumbnails of the menu waiting to replace this one are still loading.
    function preloading() {
        for (let i = 0; i < preload.count; ++i) {
            let image = preload.itemAt(i);
            if (image && image.status === Image.Loading)
                return true;
        }
        return false;
    }

    // Whether an image in the rows shown is still loading.
    function thumbnailsPending() {
        for (let i = 0; i < rows.count; ++i) {
            let row = rows.itemAt(i);
            if (row && row.thumbnailPending)
                return true;
        }
        return false;
    }

    function releaseMenu() {
        menuHeld = false;
        // The card fades in from here, not from when the menu was asked for.
        presence.velocity = 0;
        presence.value = 0;
    }

    // Like rofi -display-columns 2, a line shows the column after its first
    // tab, so cliphist's "id<TAB>preview" lines show just the preview.
    function menuEntry(line, images) {
        let columns = line.split("\t");
        let title = columns.length > 1 ? columns[1] : line;
        // cliphist lists a copied image as "id<TAB>[[ binary data 2 MiB png 1920x1080 ]]".
        // launch.sh decodes it into the images folder, in a file named by its id.
        let image = columns.length === 2 && /^\d+$/.test(columns[0]) && /^\[\[ binary data .* \d+x\d+ \]\]$/.test(title);
        // It is listed as "Image 2 MiB"; the line itself still goes back to launch.sh unchanged.
        let size = image && /^\[\[ binary data (.*) \S+ \d+x\d+ \]\]$/.exec(title);
        return {title: size ? "Image " + size[1] : title, kind: "line", line: line, icon: image ? "image-x-generic" : "text-x-generic",
                image: image && images ? fileUrl(images + "/" + columns[0]) : ""};
    }

    // Tells launch.sh which line was picked, once; null cancels the menu.
    function answerMenu(line) {
        if (!menuResult)
            return;
        let file = menuFile.createObject(root, {path: menuResult, preload: false});
        file.setText(line === null ? "cancelled\n" : "selected\n" + line + "\n");
        file.destroy();
        menuResult = "";
    }

    function activate() {
        if (shellMode) {
            let command = input.text.trim();
            if (command)
                runShell(command);
            return;
        }
        if (!results.length || selected < 0 || selected >= results.length)
            return;
        if (menuMode) {
            answerMenu(results[selected].line);
            hidePanel();
        } else {
            launch(results[selected].entry);
        }
    }

    function fileUrl(path) {
        return "file://" + encodeURI(path).replace(/#/g, "%23").replace(/\?/g, "%3F");
    }

    function iconUrl(result) {
        let fallback = result.kind === "app" ? "application-x-executable" : "text-x-generic";
        let icon = result.icon || fallback;
        return icon.startsWith("/") ? fileUrl(icon) : Quickshell.iconPath(icon, fallback);
    }

    function selectResult(index) {
        selected = index;
        selectionExplicit = true;
    }

    function hoverResult(index, position) {
        // Delegates also receive hover events when results appear or reorder.
        // Only actual movement in window coordinates should change selection.
        let previous = hoverPosition;
        hoverPosition = position;
        if (previous && (previous.x !== position.x || previous.y !== position.y))
            selectResult(index);
    }

    Component.onCompleted: {
        drunHistory = RofiSearch.parseDrunHistory(drunCache.text());
        chooseScreen();
        if (opened) {
            presence.value = 0;
            focusTimer.start();
        }
    }

    // A longer list scrolls to keep the selected one in view.
    onSelectedChanged: {
        let top = Math.min(Math.max(scroll.target, (selected - config.rows + 1) * 62), selected * 62);
        scroll.target = Math.max(0, Math.min(top, (results.length - config.rows) * 62));
    }
    onResultsChanged: {
        scroll.target = 0;
        scroll.settle();
    }

    // launch.sh hands a menu its lines in one file and waits for the answer in
    // another. Each file gets a new FileView: after a path change, one still
    // returns the last file's text and skips writing text it wrote before.
    Component {
        id: menuFile
        FileView { blockLoading: true; blockWrites: true; atomicWrites: true; printErrors: false }
    }

    IpcHandler {
        target: "spotlight"
        function toggle(): void { if (root.opened) root.hidePanel(); else root.showPanel(); }
        function present(): void { root.showPanel(); }
        function hide(): void { root.hidePanel(); }
        function quit(): void { Qt.quit(); }
        function processId(): int { return Quickshell.processId; }
        function search(query: string): void {
            if (!root.opened || root.menuMode)
                root.showPanel();
            input.text = query;
        }
        // Returns this process ID, which launch.sh watches in case the
        // instance stops before answering.
        function showMenu(linesPath: string, resultPath: string, imagesPath: string): int {
            if (root.opened && root.menuMode) {
                // Asking for a menu while one is open closes it, as its keybind toggles it. The
                // request is cancelled too, so its launch.sh exits instead of waiting for a pick.
                let cancelled = menuFile.createObject(root, {path: resultPath, preload: false});
                cancelled.setText("cancelled\n");
                cancelled.destroy();
                root.hidePanel();
                return Quickshell.processId;
            }
            let file = menuFile.createObject(root, {path: linesPath});
            let lines = file.text().split(/\r?\n/);
            file.destroy();
            // The final line break does not start another line.
            if (lines[lines.length - 1] === "")
                lines.pop();
            root.showMenu(lines, resultPath, imagesPath);
            return Quickshell.processId;
        }
        function state(): string {
            function bounds(item) {
                let start = item.mapToItem(panel.contentItem, 0, 0);
                let end = item.mapToItem(panel.contentItem, item.width, item.height);
                return {x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y};
            }
            return JSON.stringify({visible: root.opened, query: input.text, apps: root.applications.length,
                                   results: root.results.map(result => ({id: result.id, title: result.title, kind: result.kind,
                                                                         icon: result.icon, line: result.line,
                                                                         image: result.image})),
                                   selected: root.selected, menu: root.menuMode, shell: root.shellMode, scroll: scroll.target,
                                   height: (card.height + 36) * config.scale, surfaceHeight: panel.height,
                                   geometry: {card: bounds(card), firstRow: rows.count ? bounds(rows.itemAt(0)) : null,
                                              surfaceWidth: panel.width, topMargin: panel.margins.top,
                                              mask: bounds(inputShape), maskRadius: inputRegion.radius},
                                   focus: {input: input.activeFocus, navigation: navigation.activeFocus,
                                           grabbed: grab.active},
                                   screen: panel.screen.name, namespace: root.namespace,
                                   font: {family: root.fontFamily, ready: bundledFont.status === FontLoader.Ready},
                                   theme: {source: theme.path, base00: theme.base00.toString(),
                                           base05: theme.base05.toString(), accent: theme.base0D.toString(), dark: theme.dark},
                                   config: {source: config.path, opacity: config.opacity, cornerRadius: config.cornerRadius,
                                            borderOpacity: config.borderOpacity, width: config.width, topOffset: config.topOffset,
                                            scale: config.scale, rows: config.rows, placeholder: config.placeholder,
                                            font: {family: config.fontFamily, size: config.fontSize, searchSize: config.searchFontSize},
                                            search: config.searchOptions,
                                            history: {enable: config.historyEnabled, size: config.historySize}}});
        }
    }

    // Releases a held menu once its thumbnails are loaded, or after 300 ms, so a huge image cannot hold it up.
    Timer {
        interval: 16
        repeat: true
        running: root.menuHeld
        onTriggered: if (Date.now() - root.menuHeldSince > 300 || !root.thumbnailsPending()) root.releaseMenu()
    }

    Timer {
        interval: 16
        repeat: true
        running: root.pendingMenu !== null
        onTriggered: if (Date.now() - root.pendingSince > 300 || !root.preloading()) root.applyPendingMenu()
    }

    // Nix may replace a config or palette symlink without changing the watched target.
    Timer { interval: 2000; repeat: true; running: root.opened; onTriggered: { config.refresh(); theme.refresh(); } }
    Timer {
        id: monitorTimer
        interval: 300
        onTriggered: {
            root.targetScreen = Quickshell.screens[0];
            root.screenPending = false;
            if (root.opened)
                focusTimer.restart();
        }
    }
    Connections {
        target: Hyprland
        function onFocusedMonitorChanged() {
            if (!root.screenPending)
                return;
            root.chooseScreen();
            if (root.opened)
                focusTimer.restart();
        }
    }
    Timer {
        id: focusTimer
        interval: 30
        onTriggered: {
            (root.menuMode ? navigation : input).forceActiveFocus();
            if (root.isHyprland)
                grab.active = true;
        }
    }

    PanelWindow {
        id: panel
        screen: root.targetScreen
        // Stays mapped until the close fade ends.
        visible: !root.screenPending && (root.opened || fade > 0)
        onVisibleChanged: if (!visible) root.resetPanel()
        // Closing fades the card out in place; reopening fades it back in.
        property real fade: root.opened ? 1 : 0
        Behavior on fade {
            // A fresh open sets it while hidden, leaving that fade to the pop.
            enabled: panel.visible
            NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
        }
        color: "transparent"
        anchors.top: true
        margins.top: Math.min(Math.round(screen.height * config.topOffset), Math.max(0, screen.height - implicitHeight))
        implicitWidth: Math.min(Math.ceil(config.width * config.scale), screen.width - 48)
        // Keep the Wayland surface stable; only the card inside it animates.
        implicitHeight: Math.min(Math.ceil((72 + config.rows * 62 + 16 + 36) * config.scale), screen.height)
        // Clicks pass through as soon as the panel starts closing.
        mask: Region {
            id: inputRegion
            item: root.opened ? inputShape : null
            radius: inputShape.radius
        }
        BackgroundEffect.blurRegion: Region {
            item: root.opened ? inputShape : null
            radius: inputShape.radius
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: root.namespace
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        HyprlandFocusGrab {
            id: grab
            windows: [panel]
            onCleared: if (root.opened) root.hidePanel()
        }

        // All visual dimensions stay in base pixels, including fonts, rows and icons.
        // The surface uses scaled bounds so input and clipping match the rendered card.
        Item {
            id: scaledContent
            width: panel.width / config.scale
            height: panel.height / config.scale
            scale: config.scale
            transformOrigin: Item.TopLeft
        }
        // Region tracks item geometry but not transforms on ancestors. Mirror the
        // transformed card into panel coordinates so pointer input scales with it.
        Item {
            id: inputShape
            readonly property real radius: Math.round(card.radius * shape.zoom * config.scale)
            x: shape.x * config.scale
            y: shape.y * config.scale
            width: shape.width * config.scale
            height: shape.height * config.scale
        }

        // Loads the thumbnails of a menu waiting to replace this one. The rows built afterwards
        // find them in the cache, so they are there at once.
        Item {
            visible: false
            Repeater {
                id: preload
                model: root.preloadEntries
                // Set up as a thumbnail is, so the rows find what it loaded.
                delegate: Image {
                    required property var modelData
                    width: 46; height: 46
                    source: modelData.image
                    sourceSize.width: 46
                    sourceSize.height: 46
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
            }
        }

        // A new result count redirects the motion without restarting it.
        Spring {
            id: expansion
            target: Math.min(root.searchHeight + root.resultsHeight, scaledContent.height - 36)
            enabled: panel.visible
        }

        // Opening pops the card in from its search row.
        Spring {
            id: presence
            target: 1
            response: 0.16
            damping: 0.9
            precision: 0.006
            enabled: panel.visible
        }
        // The search icon turns from a magnifying glass into a shell prompt.
        Spring {
            id: shellIcon
            target: root.shellMode ? 1 : 0
            response: 0.28
            damping: 0.8
            precision: 0.002
            enabled: panel.visible
        }
        // The selection highlight glides to the selected row.
        Spring {
            id: selection
            target: root.selected * 62
            response: 0.1
            enabled: panel.visible
        }
        // A long list scrolls with the same motion, so the highlight moves with its row.
        Spring {
            id: scroll
            response: 0.1
            enabled: panel.visible
        }

        Scale {
            id: presenceScale
            origin.x: card.width / 2
            origin.y: searchRow.height / 2
            // A menu holds copied images, which resample and shimmer when scaled, so it only fades in.
            xScale: root.menuMode ? 1 : 0.9 + 0.1 * presence.value
            yScale: xScale
        }

        // The card's fill and the border Hyprland draws on floating windows (base05 at 0x33
        // alpha, 1 px). The card scales and grows on springs, and edges that land between
        // pixels shimmer, so this follows the card's edges snapped to whole device pixels.
        Item {
            id: shape
            parent: scaledContent
            z: 0
            readonly property real ratio: Math.max(0.01, panel.devicePixelRatio * config.scale)
            readonly property real zoom: presenceScale.xScale
            function snap(value) { return Math.round(value * ratio) / ratio; }
            // The card's edges after presenceScale, which scales about the search row's middle.
            readonly property real snapLeft: snap(card.x + card.width / 2 * (1 - zoom))
            readonly property real snapTop: snap(card.y + searchRow.height / 2 * (1 - zoom))
            readonly property real snapRight: snap(card.x + card.width / 2 * (1 - zoom) + card.width * zoom)
            readonly property real snapBottom: snap(card.y + searchRow.height / 2 + (card.height - searchRow.height / 2) * zoom)
            x: snapLeft
            y: snapTop
            width: snapRight - snapLeft
            height: snapBottom - snapTop
            opacity: card.opacity

            // Stops 1 px inside the edge, so the border is drawn over the desktop like a window's.
            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: Math.max(0, card.radius * shape.zoom - 1)
                color: Qt.alpha(theme.base00, config.opacity)
            }
            Rectangle {
                anchors.fill: parent
                radius: card.radius * shape.zoom
                color: "transparent"
                border.width: 1
                border.color: Qt.alpha(theme.base05, config.borderOpacity)
            }
        }

        Rectangle {
            id: card
            parent: scaledContent
            z: 1
            x: 16
            y: 12
            width: parent.width - 32
            height: expansion.value
            radius: config.cornerRadius
            color: "transparent"
            opacity: root.menuHeld ? 0 : Math.min(1, presence.value * 2) * panel.fade
            transform: presenceScale
            clip: true

            Item {
                id: searchRow
                width: parent.width
                height: 72
                visible: !root.menuMode

                Item {
                    x: 24
                    anchors.verticalCenter: parent.verticalCenter
                    width: 23
                    height: 23
                    opacity: 0.65

                    Item {
                        anchors.fill: parent
                        opacity: Math.max(0, Math.min(1, 1 - shellIcon.value))
                        scale: 1 - 0.35 * Math.min(1, shellIcon.value)
                        rotation: -40 * Math.min(1, shellIcon.value)
                        visible: opacity > 0
                        Rectangle {
                            width: 15; height: 15; radius: 8
                            color: "transparent"
                            border.width: 1.7; border.color: theme.base05
                            x: 1; y: 1
                        }
                        Rectangle {
                            width: 9; height: 1.7; radius: 1
                            color: theme.base05; rotation: 45
                            x: 13; y: 17
                        }
                    }

                    // A terminal window holding a prompt.
                    Item {
                        anchors.fill: parent
                        opacity: Math.max(0, Math.min(1, shellIcon.value))
                        scale: 0.65 + 0.35 * shellIcon.value
                        rotation: 40 * (1 - Math.min(1, shellIcon.value))
                        visible: opacity > 0
                        Rectangle {
                            width: 23; height: 19; radius: 5
                            color: "transparent"
                            border.width: 1.7; border.color: theme.base05
                            y: 2
                        }
                        // The prompt: a chevron and a cursor, stroked with round ends and joins.
                        Shape {
                            anchors.fill: parent
                            layer.enabled: true
                            layer.samples: 4
                            ShapePath {
                                strokeColor: theme.base05
                                strokeWidth: 1.7
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap
                                joinStyle: ShapePath.RoundJoin
                                PathPolyline { path: [Qt.point(6.4, 8), Qt.point(10.4, 11.5), Qt.point(6.4, 15)] }
                            }
                            ShapePath {
                                strokeColor: theme.base05
                                strokeWidth: 1.7
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap
                                PathPolyline { path: [Qt.point(12.6, 15), Qt.point(16.6, 15)] }
                            }
                        }
                    }
                }

                // The empty field's hint, drawn here instead of as the field's placeholderText so it
                // can change with the search icon: one slides up and out as the other comes in.
                Repeater {
                    model: [
                        {text: config.placeholder, shell: false},
                        {text: "Run a shell command", shell: true}
                    ]
                    Text {
                        required property var modelData
                        readonly property real amount: Math.max(0, Math.min(1, modelData.shell ? shellIcon.value : 1 - shellIcon.value))
                        x: input.x
                        // Rises 8 px as it leaves, and settles from 8 px below as it arrives.
                        y: (searchRow.height - height) / 2 + (modelData.shell ? 8 * (1 - shellIcon.value) : -8 * shellIcon.value)
                        width: input.width
                        text: modelData.text
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        font.family: root.fontFamily
                        font.pixelSize: config.searchFontSize
                        font.weight: Font.Normal
                        color: Qt.alpha(theme.base05, 0.65)
                        opacity: amount
                        visible: input.length === 0 && input.preeditText === "" && amount > 0
                    }
                }

                TextField {
                    id: input
                    x: 62
                    width: parent.width - x - 24
                    height: parent.height
                    padding: 0
                    font.family: root.fontFamily
                    font.pixelSize: config.searchFontSize
                    font.weight: Font.Normal
                    color: theme.base05
                    selectionColor: theme.base0D
                    selectedTextColor: theme.base00
                    background: Item {}
                    focus: true
                    selectByMouse: true
                    // The caret waits for the first typed character; the placeholder shows without it.
                    // Gaining focus turns it on, so an empty field turns it straight off again.
                    onCursorVisibleChanged: if (cursorVisible && length === 0) cursorVisible = false
                    onLengthChanged: cursorVisible = length > 0 && activeFocus
                    Accessible.name: "Search applications"
                    onTextChanged: {
                        if (!root.menuMode && !root.shellMode && text.startsWith("!")) {
                            root.shellMode = true;
                            // The change this makes runs the rest.
                            text = text.slice(1);
                            return;
                        }
                        root.selected = 0;
                        root.selectionExplicit = false;
                        root.hoverPosition = null;
                        root.matchApps();
                    }
                    Keys.forwardTo: [navigation]
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Backspace && root.shellMode && length === 0) {
                            root.shellMode = false;
                            root.matchApps();
                            event.accepted = true;
                        }
                    }
                }

            }

            // Moves through the results and picks one. The search field passes its
            // keys here first; a menu, which has no search field, focuses this instead.
            Item {
                id: navigation
                Keys.onEscapePressed: root.hidePanel()
                // Like the wheel, the keys stop at the first and last rows.
                Keys.onDownPressed: event => {
                    if (root.results.length)
                        root.selectResult(Math.min(root.selected + 1, root.results.length - 1));
                    event.accepted = true;
                }
                Keys.onUpPressed: event => {
                    if (root.results.length)
                        root.selectResult(Math.max(root.selected - 1, 0));
                    event.accepted = true;
                }
                // Tab and Shift+Tab step the same way as Down and Up.
                Keys.onTabPressed: event => {
                    if (root.results.length)
                        root.selectResult(Math.min(root.selected + 1, root.results.length - 1));
                    event.accepted = true;
                }
                Keys.onBacktabPressed: event => {
                    if (root.results.length)
                        root.selectResult(Math.max(root.selected - 1, 0));
                    event.accepted = true;
                }
                Keys.onReturnPressed: root.activate()
                Keys.onEnterPressed: root.activate()
            }

            Rectangle {
                x: 20; y: 72
                width: parent.width - 40; height: 1
                color: Qt.alpha(theme.base05, 0.09)
                visible: searchRow.visible && root.results.length > 0
            }

            Item {
                x: 8
                y: root.searchHeight + 8
                width: parent.width - 16
                // Keep rows inside the rounded corners while the card grows.
                height: Math.max(0, card.height - y - 8)
                clip: true
                visible: root.results.length > 0

                // The wheel scrolls a long list a row per notch and leaves the selection where
                // it is, so the highlight scrolls away with its row.
                WheelHandler {
                    target: null
                    // Touchpads scroll too, and Qt reports some mouse wheels as one.
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => {
                        let limit = Math.max(0, (root.results.length - config.rows) * 62);
                        scroll.target = Math.max(0, Math.min(scroll.target - event.angleDelta.y / 120 * 62, limit));
                    }
                }

                // One highlight moves between the rows, drawn beneath them.
                // Rows past the seventh scroll up from under the clip.
                Rectangle {
                    y: selection.value - scroll.value
                    width: parent.width
                    // Stops at the bottom of the rows shown, so while the card grows its
                    // corners there stay round instead of being cut off.
                    height: Math.max(0, Math.min(62, parent.height - y))
                    // Concentric with the card's corners, which are 8 px further out.
                    radius: Math.max(0, card.radius - 8)
                    color: Qt.alpha(theme.base02, 0.26)
                }

                Repeater {
                    id: rows
                    model: root.results
                    delegate: Item {
                        id: resultRow
                        required property var modelData
                        required property int index
                        // 1 under the highlight, 0 a row away, so the name brightens as it arrives.
                        readonly property real lit: Math.max(0, 1 - Math.abs(selection.value - index * 62) / height)
                        // In the rows shown, or scrolling into them.
                        readonly property bool inView: y + height > 0 && y < config.rows * 62
                        readonly property real createdAt: Date.now()
                        // A copied image that could not be loaded, so the row shows its icon instead.
                        readonly property bool imageFailed: Boolean(modelData.image) && thumbnail.item !== null && thumbnail.item.failed
                        // A copied image shown here that has not finished loading.
                        readonly property bool thumbnailPending: Boolean(modelData.image) && inView
                            && !(thumbnail.item && thumbnail.item.settled)
                        y: index * 62 - scroll.value
                        width: card.width - 16
                        height: 62

                        Image {
                            id: resultIcon
                            x: 16; y: 14
                            width: 32; height: 32
                            // One letter can match dozens of apps. Loading all their icons at once,
                            // on the UI thread, held up typing, for about 400 ms after a fresh start.
                            source: resultRow.inView && showing ? root.iconUrl(resultRow.modelData) : ""
                            sourceSize.width: 32
                            sourceSize.height: 32
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            // A copied image shows only its thumbnail, with no placeholder icon while it loads.
                            readonly property bool showing: !Boolean(resultRow.modelData.image) || resultRow.imageFailed
                            visible: showing
                        }

                        Rectangle {
                            x: 20; y: 17
                            width: 23; height: 28; radius: 4
                            color: theme.base01
                            border.color: theme.base03
                            visible: resultIcon.visible && resultIcon.status === Image.Error
                            Text {
                                anchors.centerIn: parent
                                text: resultRow.modelData.kind === "app" ? "⌘" : "≡"
                                font.pixelSize: 15
                                color: theme.base05
                            }
                        }

                        // A copied image, cropped to a square whose corners are concentric
                        // with the card's, 16 px further out.
                        Loader {
                            id: thumbnail
                            readonly property bool ready: item !== null && item.ready
                            x: 8; y: 8
                            width: 46; height: 46
                            active: Boolean(resultRow.modelData.image)
                            opacity: 0
                            visible: opacity > 0
                            // One that is there as its row is built, from the cache, shows at once.
                            // One that loads fades in.
                            onReadyChanged: {
                                fadeIn.stop();
                                if (!ready)
                                    opacity = 0;
                                else if (Date.now() - resultRow.createdAt < 30)
                                    opacity = 1;
                                else
                                    fadeIn.start();
                            }
                            NumberAnimation { id: fadeIn; target: thumbnail; property: "opacity"; to: 1; duration: 140; easing.type: Easing.OutQuad }
                            sourceComponent: ClippingRectangle {
                                readonly property bool ready: picture.status === Image.Ready
                                readonly property bool failed: picture.status === Image.Error
                                readonly property bool settled: ready || failed
                                radius: Math.max(0, card.radius - 16)
                                color: "transparent"
                                Image {
                                    id: picture
                                    anchors.fill: parent
                                    source: resultRow.inView ? resultRow.modelData.image : ""
                                    sourceSize.width: 46
                                    sourceSize.height: 46
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                            }
                        }

                        Text {
                            x: 64
                            y: (parent.height - height) / 2
                            width: parent.width - x - 20
                            text: resultRow.modelData.title
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            font.family: root.fontFamily
                            font.pixelSize: config.fontSize
                            font.weight: Font.Medium
                            color: Qt.tint(root.titleColor, Qt.alpha(root.selectedTitleColor, resultRow.lit))
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: mouse => root.hoverResult(resultRow.index, mapToItem(panel.contentItem, mouse.x, mouse.y))
                            onClicked: {
                                root.selectResult(resultRow.index);
                                root.activate();
                            }
                        }
                    }
                }
            }
        }
    }
}
