import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Services

PluginSettings {
    id: root
    pluginId: "nixPackageRunner"

    Component.onCompleted: {
        const triggerValue = root.loadValue("trigger", undefined);
        if (triggerValue === undefined || triggerValue === null || String(triggerValue).trim().length === 0)
            root.saveValue("trigger", "nix");

        const terminalValue = root.loadValue("terminal", undefined);
        if (terminalValue === undefined || terminalValue === null || String(terminalValue).trim().length === 0)
            root.saveValue("terminal", "kitty");

        const execFlagValue = root.loadValue("execFlag", undefined);
        if (execFlagValue === undefined || execFlagValue === null || String(execFlagValue).trim().length === 0)
            root.saveValue("execFlag", "-e");

        const maxResultsValue = parseInt(root.loadValue("maxResults", undefined));
        if (isNaN(maxResultsValue) || maxResultsValue < 1)
            root.saveValue("maxResults", 8);

        const allowUnfreeValue = root.loadValue("allowUnfree", undefined);
        if (allowUnfreeValue === undefined || allowUnfreeValue === null)
            root.saveValue("allowUnfree", true);

        const runInTerminalValue = root.loadValue("runInTerminal", undefined);
        if (runInTerminalValue === undefined || runInTerminalValue === null)
            root.saveValue("runInTerminal", false);

        const runSourceModeValue = root.loadValue("runSourceMode", undefined);
        if (runSourceModeValue === undefined || runSourceModeValue === null || String(runSourceModeValue).trim().length === 0)
            root.saveValue("runSourceMode", "local_locked");
    }

    StyledText {
        width: parent.width
        text: "Nix Package Runner"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Search nixpkgs with nix search, launch directly with nix run, and copy nix shell commands from the context menu."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Prefix used to activate the plugin."
        placeholder: "nix"
        defaultValue: "nix"
    }

    ToggleSetting {
        settingKey: "runInTerminal"
        label: "Run in terminal by default"
        description: value ? "Launcher opens terminal for package runs." : "Launcher runs packages directly."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "allowUnfree"
        label: "Allow unfree packages"
        description: value ? "Runs nix commands with NIXPKGS_ALLOW_UNFREE=1 and uses --impure where required." : "Only free packages can be launched."
        defaultValue: true
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    SelectionSetting {
        settingKey: "runSourceMode"
        label: "Run Source"
        description: "Only package launch and copied nix shell commands use this source. Search still uses your local nixpkgs."
        defaultValue: "local_locked"
        options: [{
            label: "Local locked",
            value: "local_locked"
        }, {
            label: "Latest unstable",
            value: "latest_unstable"
        }]
    }

    StyledText {
        width: parent.width
        text: "Local locked resolves the main nixpkgs input from /etc/nixos/flake.lock. Latest unstable uses github:NixOS/nixpkgs/nixos-unstable."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        leftPadding: Theme.spacingM
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Search Results"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    Row {
        width: parent.width
        spacing: Theme.spacingM

        StyledText {
            text: "Max results"
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceText
            anchors.verticalCenter: parent.verticalCenter
        }

        DankTextField {
            width: 80
            text: root.loadValue("maxResults", "8").toString()
            placeholderText: "8"
            onTextEdited: {
                const number = parseInt(text);
                if (!isNaN(number) && number > 0 && number <= 20)
                    root.saveValue("maxResults", number);
            }
        }

        StyledText {
            text: "(1-20)"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Terminal"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Used for the context menu terminal action and optional default terminal mode."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Row {
        width: parent.width
        spacing: Theme.spacingM

        Column {
            width: (parent.width - Theme.spacingM) / 2
            spacing: Theme.spacingXS

            StyledText {
                text: "Command"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankTextField {
                width: parent.width
                text: root.loadValue("terminal", "kitty")
                placeholderText: "kitty"
                onTextEdited: root.saveValue("terminal", text.trim())
            }
        }

        Column {
            width: (parent.width - Theme.spacingM) / 2
            spacing: Theme.spacingXS

            StyledText {
                text: "Exec flag"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankTextField {
                width: parent.width
                text: root.loadValue("execFlag", "-e")
                placeholderText: "-e"
                onTextEdited: root.saveValue("execFlag", text.trim())
            }
        }
    }

    StyledText {
        width: parent.width
        text: "Common values: kitty (-e), foot (-e), alacritty (-e), gnome-terminal (--), konsole (-e), wezterm (start)"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        leftPadding: Theme.spacingM
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    DankButton {
        text: "Clear Recent Packages"
        iconName: "delete"
        backgroundColor: Theme.error
        textColor: Theme.surface
        onClicked: {
            root.saveState("recentPackages", []);
            ToastService?.showInfo("Recent packages cleared");
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    Column {
        width: parent.width
        spacing: Theme.spacingXS
        bottomPadding: Theme.spacingL

        StyledText {
            width: parent.width
            text: "Usage"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: "1. Open launcher and type your trigger, for example: nix helix"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        StyledText {
            width: parent.width
            text: "2. Press Enter to launch with nix run, or use the context menu for terminal and copy actions."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }
}
