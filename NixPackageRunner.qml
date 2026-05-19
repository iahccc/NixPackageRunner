import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

Item {
    id: root

    property var pluginService: null
    property string pluginId: "nixPackageRunner"
    property string trigger: "nix"
    property string pendingQuery: ""
    property string pendingCacheKey: ""
    property string activeCacheKey: ""
    property var cachedResults: ({})
    property var cacheAccessOrder: []
    property var recentPackages: []
    property var currentSearchProcess: null
    property var searchDebounce: null
    property int currentSearchToken: 0
    readonly property int minQueryLength: 2
    readonly property int maxRecentItems: 10
    readonly property int cacheMaxEntries: 64
    readonly property int cacheTtlMs: 5 * 60 * 1000
    readonly property string helperScriptPath: root.toLocalPath(Qt.resolvedUrl("nix-package-runner.sh"))
    readonly property string localLockedRunSourceRef: "__LOCAL_LOCKED_NIXPKGS__"
    readonly property string latestUnstableRunSourceRef: "github:NixOS/nixpkgs/nixos-unstable"

    signal itemsChanged

    Component.onCompleted: {
        root.ensureSearchDebounce();
        trigger = root.loadStringSetting("trigger", "nix");
        recentPackages = root.loadState("recentPackages", []);
    }

    function getItems(query) {
        const normalized = root.normalizeQuery(query);
        const cacheKey = root.buildCacheKey(normalized);
        const cached = root.getCachedResults(cacheKey);
        if (!normalized)
            return root.buildIdleItems();

        if (normalized.length < minQueryLength)
            return [root.makeInfoItem("Keep typing", "Type at least " + minQueryLength + " characters to search nixpkgs.", 1000)];

        if (cached !== undefined)
            return root.buildResultItems(cached);

        if (activeCacheKey !== cacheKey || !currentSearchProcess)
            root.scheduleSearch(normalized, cacheKey);

        return root.buildLoadingItems(normalized);
    }

    function executeItem(item) {
        const parsed = root.parseAction(item);
        if (!parsed)
            return;

        if (parsed.type === "noop")
            return;

        if (parsed.type === "launch") {
            root.launchPackage(parsed.payload, root.loadBoolSetting("runInTerminal", false));
            return;
        }

        if (parsed.type === "launch-terminal") {
            root.launchPackage(parsed.payload, true);
            return;
        }

        if (parsed.type === "copy-attr") {
            root.copyToClipboard(parsed.payload.attrPath);
            root.showToast("Copied attr path", parsed.payload.attrPath);
            return;
        }

        if (parsed.type === "copy-command") {
            root.copyCommandToClipboard(parsed.payload);
            return;
        }
    }

    function getContextMenuActions(item) {
        const parsed = root.parseAction(item);
        if (!parsed || parsed.type === "noop")
            return [];

        if (parsed.type !== "launch")
            return [];

        return [{
            icon: "play_arrow",
            text: "Run",
            closeLauncher: true,
            action: () => root.launchPackage(parsed.payload, false)
        }, {
            icon: "terminal",
            text: "Run in terminal",
            closeLauncher: true,
            action: () => root.launchPackage(parsed.payload, true)
        }, {
            icon: "content_copy",
            text: "Copy nix shell command",
            action: () => root.copyCommandToClipboard(parsed.payload)
        }, {
            icon: "inventory_2",
            text: "Copy attr path",
            action: () => {
                root.copyToClipboard(parsed.payload.attrPath);
                root.showToast("Copied attr path", parsed.payload.attrPath);
            }
        }];
    }

    function scheduleSearch(query, cacheKey) {
        root.ensureSearchDebounce();
        pendingQuery = query;
        pendingCacheKey = cacheKey;
        searchDebounce.restart();
    }

    function startSearch(query, cacheKey) {
        if (!query || query.length < minQueryLength)
            return;

        if (currentSearchProcess) {
            currentSearchProcess.running = false;
            currentSearchProcess = null;
        }

        activeCacheKey = cacheKey;
        currentSearchToken += 1;
        currentSearchProcess = root.createSearchProcess(query, cacheKey, currentSearchToken);

        root.requestRefresh();
    }

    function finishSearch(requestToken, query, cacheKey, exitCode, stdoutBuffer, stderrBuffer) {
        if (requestToken !== currentSearchToken)
            return;

        activeCacheKey = "";
        currentSearchProcess = null;

        if (exitCode !== 0) {
            root.storeResults(cacheKey, {
                items: [],
                error: stderrBuffer && stderrBuffer.trim().length > 0 ? stderrBuffer.trim() : "nix search failed"
            });
            root.requestRefresh();
            return;
        }

        try {
            const parsed = JSON.parse(stdoutBuffer || "{}");
            root.storeResults(cacheKey, {
                items: root.parseSearchResults(query, parsed),
                error: ""
            });
        } catch (error) {
            console.log("[NixPackageRunner] parse error:", error);
            root.storeResults(cacheKey, {
                items: [],
                error: "Invalid nix search output"
            });
        }

        root.requestRefresh();
    }

    function ensureSearchDebounce() {
        if (searchDebounce)
            return;

        searchDebounce = Qt.createQmlObject("import QtQuick; Timer { repeat: false }", root);
        searchDebounce.interval = 350;
        searchDebounce.triggered.connect(function () {
            root.startSearch(root.pendingQuery, root.pendingCacheKey);
        });
    }

    function createSearchProcess(query, cacheKey, requestToken) {
        const proc = Qt.createQmlObject("import Quickshell.Io; Process { running: false }", root);
        const stdoutCollector = Qt.createQmlObject("import Quickshell.Io; StdioCollector {}", proc);
        const stderrCollector = Qt.createQmlObject("import Quickshell.Io; StdioCollector {}", proc);
        const command = [root.helperScriptPath];
        const allowUnfree = root.loadBoolSetting("allowUnfree", true);

        let stdoutText = "";
        let stderrText = "";
        let exitSeen = false;
        let stdoutSeen = false;
        let stderrSeen = false;
        let exitCode = -1;

        proc.stdout = stdoutCollector;
        proc.stderr = stderrCollector;
        if (allowUnfree)
            command.push("--allow-unfree");
        command.push("search");
        command.push(query);
        proc.command = command;

        stdoutCollector.streamFinished.connect(function () {
            stdoutText = stdoutCollector.text || "";
            stdoutSeen = true;
            maybeComplete();
        });

        stderrCollector.streamFinished.connect(function () {
            stderrText = stderrCollector.text || "";
            stderrSeen = true;
            maybeComplete();
        });

        proc.exited.connect(function (code) {
            exitSeen = true;
            exitCode = code;
            maybeComplete();
        });

        function maybeComplete() {
            if (!exitSeen || !stdoutSeen || !stderrSeen)
                return;
            try {
                proc.destroy();
            } catch (error) {
                console.log("[NixPackageRunner] process destroy error:", error);
            }
            root.finishSearch(requestToken, query, cacheKey, exitCode, stdoutText, stderrText);
        }

        proc.running = true;
        return proc;
    }

    function storeResults(cacheKey, entry) {
        const now = Date.now();
        root.pruneExpiredCache(now);
        const nextCache = Object.assign({}, cachedResults);
        nextCache[cacheKey] = {
            items: entry?.items || [],
            error: entry?.error || "",
            storedAt: now
        };
        cachedResults = nextCache;
        root.touchCacheKey(cacheKey);
        root.enforceCacheLimit();
    }

    function getCachedResults(cacheKey) {
        if (!cacheKey)
            return undefined;

        const now = Date.now();
        root.pruneExpiredCache(now);

        const entry = cachedResults[cacheKey];
        if (entry === undefined)
            return undefined;

        root.touchCacheKey(cacheKey);
        return entry;
    }

    function touchCacheKey(cacheKey) {
        const nextOrder = [];
        for (let index = 0; index < cacheAccessOrder.length; index += 1) {
            const key = cacheAccessOrder[index];
            if (key && key !== cacheKey)
                nextOrder.push(key);
        }
        nextOrder.push(cacheKey);
        cacheAccessOrder = nextOrder;
    }

    function removeCacheKey(cacheKey) {
        if (!cacheKey)
            return;

        const nextCache = Object.assign({}, cachedResults);
        delete nextCache[cacheKey];
        cachedResults = nextCache;

        const nextOrder = [];
        for (let index = 0; index < cacheAccessOrder.length; index += 1) {
            const key = cacheAccessOrder[index];
            if (key && key !== cacheKey)
                nextOrder.push(key);
        }
        cacheAccessOrder = nextOrder;
    }

    function pruneExpiredCache(now) {
        const currentTime = now || Date.now();
        const nextCache = Object.assign({}, cachedResults);
        const nextOrder = [];
        let cacheChanged = false;
        let orderChanged = false;

        for (let index = 0; index < cacheAccessOrder.length; index += 1) {
            const key = cacheAccessOrder[index];
            const entry = nextCache[key];
            if (!entry) {
                orderChanged = true;
                continue;
            }

            if (!entry.storedAt || currentTime - entry.storedAt > cacheTtlMs) {
                delete nextCache[key];
                cacheChanged = true;
                orderChanged = true;
                continue;
            }

            nextOrder.push(key);
        }

        if (cacheChanged)
            cachedResults = nextCache;
        if (orderChanged)
            cacheAccessOrder = nextOrder;
    }

    function enforceCacheLimit() {
        let nextCache = Object.assign({}, cachedResults);
        let nextOrder = cacheAccessOrder.slice();
        let cacheChanged = false;

        while (nextOrder.length > cacheMaxEntries) {
            const oldestKey = nextOrder.shift();
            if (oldestKey && nextCache[oldestKey] !== undefined) {
                delete nextCache[oldestKey];
                cacheChanged = true;
            }
        }

        if (cacheChanged)
            cachedResults = nextCache;
        if (nextOrder.length !== cacheAccessOrder.length)
            cacheAccessOrder = nextOrder;
    }

    function parseSearchResults(query, parsed) {
        const entries = [];

        for (const fullAttrPath in parsed) {
            const entry = parsed[fullAttrPath] || {};
            const attrPath = root.normalizeAttrPath(fullAttrPath);
            if (!root.isRunnableAttr(attrPath))
                continue;

            const pname = entry.pname || attrPath.split(".").pop();
            const version = entry.version || "";
            const description = entry.description || "";
            entries.push({
                attrPath: attrPath,
                pname: pname,
                version: version,
                description: description,
                score: root.computeScore(query, attrPath, pname, description)
            });
        }

        entries.sort((left, right) => {
            if (right.score !== left.score)
                return right.score - left.score;
            if (left.attrPath.length !== right.attrPath.length)
                return left.attrPath.length - right.attrPath.length;
            return left.attrPath.localeCompare(right.attrPath);
        });

        return entries.slice(0, Math.max(root.loadIntSetting("maxResults", 8), 1));
    }

    function buildIdleItems() {
        if (!recentPackages || recentPackages.length === 0) {
            return [root.makeInfoItem("Search nixpkgs", "Type your trigger and a package name, for example: " + trigger + " helix")];
        }

        const items = [root.makeInfoItem("Recent packages", "Recently launched nixpkgs packages.")];
        for (let index = 0; index < recentPackages.length; index += 1)
            items.push(root.makePackageItem(recentPackages[index], index, "history"));
        return items;
    }

    function buildLoadingItems(query) {
        return [root.makeInfoItem("Searching nixpkgs", "Searching for \"" + query + "\"...", 1000)];
    }

    function buildResultItems(entry) {
        const results = entry?.items || [];
        const error = entry?.error || "";

        if (results.length === 0) {
            const message = error ? error : "No matching packages found.";
            return [root.makeInfoItem("No results", message, 1000)];
        }

        const items = [];
        for (let index = 0; index < results.length; index += 1)
            items.push(root.makePackageItem(results[index], index, "search"));
        return items;
    }

    function makePackageItem(pkg, index, source) {
        const commentParts = [];
        if (source === "history")
            commentParts.push("Recent");
        if (pkg.pname && pkg.pname !== pkg.attrPath.split(".").pop())
            commentParts.push(pkg.pname);
        if (pkg.version)
            commentParts.push("v" + pkg.version);

        let comment = commentParts.join(" | ");
        if (pkg.description) {
            comment = comment ? comment + " - " + pkg.description : pkg.description;
        } else if (!comment) {
            comment = "nixpkgs#" + pkg.attrPath;
        }

        return {
            name: pkg.attrPath,
            icon: source === "history" ? "material:history" : "material:package_2",
            comment: comment,
            action: "launch:" + JSON.stringify({
                attrPath: pkg.attrPath,
                pname: pkg.pname || "",
                version: pkg.version || "",
                description: pkg.description || ""
            }),
            categories: ["Nix Packages"],
            keywords: [pkg.attrPath, pkg.pname || "", pkg.version || ""],
            _preScored: 1000 - index
        };
    }

    function makeInfoItem(name, comment, preScored) {
        return {
            name: name,
            icon: "material:info",
            comment: comment,
            action: "noop",
            categories: ["Nix Packages"],
            _preScored: preScored
        };
    }

    function parseAction(item) {
        if (!item || !item.action)
            return null;

        const separatorIndex = item.action.indexOf(":");
        if (separatorIndex < 0)
            return {
                type: item.action,
                payload: null
            };

        const type = item.action.substring(0, separatorIndex);
        const payloadText = item.action.substring(separatorIndex + 1);
        if (type === "noop")
            return {
                type: "noop",
                payload: null
            };

        try {
            return {
                type: type,
                payload: JSON.parse(payloadText)
            };
        } catch (error) {
            console.log("[NixPackageRunner] action parse error:", error);
            return null;
        }
    }

    function launchPackage(pkg, useTerminal) {
        if (!pkg || !pkg.attrPath)
            return;

        const args = [];
        const allowUnfree = root.loadBoolSetting("allowUnfree", true);
        const runFlakeRef = root.getRunFlakeRef();
        if (useTerminal) {
            const terminal = root.loadStringSetting("terminal", "kitty").trim();
            const execFlag = root.loadStringSetting("execFlag", "-e").trim();
            if (!terminal || !execFlag) {
                root.showToast("Terminal is not configured", "Set terminal command and exec flag in plugin settings.");
                return;
            }

            args.push(terminal);
            args.push(execFlag);
            args.push(root.helperScriptPath);
            if (allowUnfree)
                args.push("--allow-unfree");
            args.push("run-wait");
        } else {
            args.push(root.helperScriptPath);
            if (allowUnfree)
                args.push("--allow-unfree");
            args.push("run");
        }

        args.push(runFlakeRef);
        args.push(pkg.attrPath);
        if (pkg.pname)
            args.push(pkg.pname);

        Quickshell.execDetached(args);
        root.rememberPackage(pkg);
        if (useTerminal)
            root.showToast("Opening in terminal", pkg.attrPath);
        else
            root.showToast("Launching with nix run", pkg.attrPath);
    }

    function rememberPackage(pkg) {
        const updated = [];
        updated.push({
            attrPath: pkg.attrPath,
            pname: pkg.pname || "",
            version: pkg.version || "",
            description: pkg.description || ""
        });

        for (let index = 0; index < recentPackages.length; index += 1) {
            const existing = recentPackages[index];
            if (!existing || existing.attrPath === pkg.attrPath)
                continue;
            updated.push(existing);
            if (updated.length >= maxRecentItems)
                break;
        }

        recentPackages = updated;
        root.saveState("recentPackages", recentPackages);
        root.requestRefresh();
    }

    function copyCommandToClipboard(pkg) {
        if (!pkg || !pkg.attrPath)
            return;

        const allowUnfree = root.loadBoolSetting("allowUnfree", true);
        const runFlakeRef = root.getRunFlakeRef();
        let command = root.shellQuote(root.helperScriptPath) + " ";
        if (allowUnfree)
            command += "--allow-unfree ";
        command += "print " + root.shellQuote(runFlakeRef) + " " + root.shellQuote(pkg.attrPath) + " " + root.shellQuote(pkg.pname || "") + " | tr -d '\\n' | wl-copy";
        Quickshell.execDetached(["sh", "-lc", command]);
        root.showToast("Copied nix shell command", root.describeRunSource() + "#" + pkg.attrPath);
    }

    function copyToClipboard(text) {
        Quickshell.execDetached(["sh", "-lc", "printf '%s' " + root.shellQuote(text) + " | wl-copy"]);
    }

    function showToast(title, message) {
        if (typeof ToastService !== "undefined")
            ToastService.showInfo(title, message);
    }

    function requestRefresh() {
        itemsChanged();
        if (pluginService && pluginService.requestLauncherUpdate)
            pluginService.requestLauncherUpdate(pluginId);
    }

    function normalizeQuery(query) {
        return query ? query.trim() : "";
    }

    function buildCacheKey(query) {
        const allowUnfree = root.loadBoolSetting("allowUnfree", true) ? "1" : "0";
        const maxResults = String(Math.max(root.loadIntSetting("maxResults", 8), 1));
        return query + "::allowUnfree=" + allowUnfree + "::maxResults=" + maxResults;
    }

    function getRunFlakeRef() {
        const mode = root.loadStringSetting("runSourceMode", "local_locked");
        if (mode === "latest_unstable")
            return latestUnstableRunSourceRef;
        return localLockedRunSourceRef;
    }

    function describeRunSource() {
        const mode = root.loadStringSetting("runSourceMode", "local_locked");
        if (mode === "latest_unstable")
            return latestUnstableRunSourceRef;
        return "local locked nixpkgs";
    }

    function normalizeAttrPath(fullAttrPath) {
        const prefix = "legacyPackages.";
        if (fullAttrPath.startsWith(prefix)) {
            const parts = fullAttrPath.split(".");
            if (parts.length > 2)
                return parts.slice(2).join(".");
        }
        return fullAttrPath;
    }

    function isRunnableAttr(attrPath) {
        if (!attrPath || attrPath.startsWith("tests.") || attrPath.startsWith("checks.") || attrPath.startsWith("_"))
            return false;

        const blockedSegments = ["callPackage", "newScope", "override", "overrideScope", "packages", "recurseForDerivations"];
        const segments = attrPath.split(".");
        for (let index = 0; index < segments.length; index += 1) {
            if (blockedSegments.indexOf(segments[index]) >= 0)
                return false;
        }

        return true;
    }

    function computeScore(query, attrPath, pname, description) {
        const normalizedQuery = query.toLowerCase();
        const attr = attrPath.toLowerCase();
        const packageName = (pname || "").toLowerCase();
        const details = (description || "").toLowerCase();
        let score = 0;

        if (attr === normalizedQuery)
            score += 5000;
        if (packageName === normalizedQuery)
            score += 4500;
        if (attr.startsWith(normalizedQuery))
            score += 2500;
        if (packageName.startsWith(normalizedQuery))
            score += 2200;
        if (attr.includes("." + normalizedQuery))
            score += 900;
        if (attr.indexOf(normalizedQuery) >= 0)
            score += 500;
        if (packageName.indexOf(normalizedQuery) >= 0)
            score += 400;
        if (details.indexOf(normalizedQuery) >= 0)
            score += 120;

        score -= attr.split(".").length * 12;
        score -= attr.length;
        return score;
    }

    function shellQuote(value) {
        const text = value === undefined || value === null ? "" : String(value);
        return "'" + text.replace(/'/g, "'\"'\"'") + "'";
    }

    function toLocalPath(urlValue) {
        let value = String(urlValue);
        if (value.startsWith("file://"))
            value = value.substring(7);
        return decodeURIComponent(value);
    }

    function loadStringSetting(key, defaultValue) {
        if (!pluginService)
            return defaultValue;
        const value = pluginService.loadPluginData(pluginId, key, defaultValue);
        if (value === undefined || value === null)
            return defaultValue;
        return String(value);
    }

    function loadIntSetting(key, defaultValue) {
        const value = parseInt(root.loadStringSetting(key, String(defaultValue)));
        return isNaN(value) ? defaultValue : value;
    }

    function loadBoolSetting(key, defaultValue) {
        if (!pluginService)
            return defaultValue;
        const value = pluginService.loadPluginData(pluginId, key, defaultValue);
        if (value === undefined || value === null)
            return defaultValue;
        if (typeof value === "string")
            return value === "true";
        return Boolean(value);
    }

    function loadState(key, defaultValue) {
        if (!pluginService || !pluginService.loadPluginState)
            return defaultValue;
        return pluginService.loadPluginState(pluginId, key, defaultValue);
    }

    function saveState(key, value) {
        if (pluginService && pluginService.savePluginState)
            pluginService.savePluginState(pluginId, key, value);
    }
}
