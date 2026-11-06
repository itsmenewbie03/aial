import QtQuick
import Quickshell

ShellRoot {
    id: root

    Component.onCompleted: Quickshell.watchFiles = false

    function checkConfig() {
        const config = configLoader.item;
        if (!config) {
            console.error("FAIL: could not load Config.qml");
            Qt.exit(1);
            return;
        }
        const expected = JSON.parse(Quickshell.env("AIAL_EXPECT_CONFIG"));
        for (const key of Object.keys(expected)) {
            if (config[key] !== expected[key]) {
                console.error("FAIL: " + key + " expected " + expected[key] + ", got " + config[key]);
                Qt.exit(1);
                return;
            }
        }
        console.info("PASS: JSON settings contract");
        Qt.quit();
    }

    Loader {
        id: configLoader
        source: "file://" + encodeURI(Quickshell.env("AIAL_SOURCE_DIR") + "/Config.qml")
            .replace(/#/g, "%23").replace(/\?/g, "%3F")
        onLoaded: Qt.callLater(root.checkConfig)
        onStatusChanged: if (status === Loader.Error) Qt.callLater(root.checkConfig)
    }
}
