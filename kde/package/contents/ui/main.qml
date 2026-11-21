import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

import "../code/usage.js" as U

PlasmoidItem {
    id: root

    // MARK: - State (UsageStore.swift)

    property var snapshot: null          // { limits, extra, fetchedAt }
    property var error: null             // U.errorInfo(...)
    property string credentialPlan: ""
    readonly property string plan: Plasmoid.configuration.cachedPlan || credentialPlan
    property real profileFetchedAt: 0
    property bool refreshing: false
    property real now: Date.now()
    property var credential: null
    property real backoffUntil: 0
    property real lastTick: Date.now()

    readonly property int refreshSeconds: Math.max(30, Plasmoid.configuration.refreshInterval)
    readonly property var metrics: String(Plasmoid.configuration.metrics).split(",")
        .map(s => s.trim()).filter(s => s.length > 0)
    readonly property var limits: snapshot ? snapshot.limits.map(l => U.effective(l, now)) : []
    readonly property var panelLimits: U.selectLimits(limits, metrics)
    readonly property bool stale: snapshot !== null
        && now - snapshot.fetchedAt > Math.max(refreshSeconds * 3, 15 * 60) * 1000
    readonly property int worstSeverity: limits.reduce((m, l) => Math.max(m, U.severity(l)), 0)

    readonly property bool planar: Plasmoid.formFactor === PlasmaCore.Types.Planar
        || Plasmoid.formFactor === PlasmaCore.Types.MediaCenter

    // MARK: - Colors (Preferences.swift ColorMode)

    readonly property color clay: "#D97757"

    /// Panel fill: the panel's own text color until a limit needs attention.
    function panelColor(sev) {
        const mode = Plasmoid.configuration.colorMode
        if (mode === "monochrome") return Kirigami.Theme.textColor
        if (sev >= U.Severity.critical) return Kirigami.Theme.negativeTextColor
        if (mode === "warnings") return sev === U.Severity.warning ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
        return clay
    }

    /// Bar and ring color in the popup and desktop widget.
    function uiColor(sev) {
        const mode = Plasmoid.configuration.colorMode
        if (mode === "monochrome") return alpha(Kirigami.Theme.textColor, 0.75)
        if (sev >= U.Severity.critical) return Kirigami.Theme.negativeTextColor
        if (mode === "warnings" && sev === U.Severity.warning) return Kirigami.Theme.neutralTextColor
        return clay
    }

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    function formatTime(d) { return d.toLocaleTimeString(Qt.locale(), Locale.ShortFormat) }
    function formatDayTime(d) { return Qt.locale().toString(d, "ddd") + " " + formatTime(d) }
    function resetPhrase(limit) { return U.resetPhrase(limit, now, formatTime, formatDayTime) }

    // MARK: - Representations

    Plasmoid.icon: "office-chart-bar-percentage"
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground
    Plasmoid.status: worstSeverity >= U.Severity.critical ? PlasmaCore.Types.NeedsAttentionStatus
                                                          : PlasmaCore.Types.ActiveStatus

    preferredRepresentation: planar ? fullRepresentation : compactRepresentation
    compactRepresentation: CompactRepresentation {}
    fullRepresentation: planar ? desktopComponent : popupComponent

    Component { id: desktopComponent; DesktopView {} }
    Component { id: popupComponent; PopupView {} }

    toolTipMainText: plan ? i18n("Claude Usage · %1", plan) : i18n("Claude Usage")
    toolTipSubText: {
        if (limits.length === 0) return error ? error.title : i18n("Loading…")
        let lines = limits.map(l => l.title + ": " + U.percentText(l.percent) + " · " + resetPhrase(l))
        if (error) lines.push(error.title + (snapshot ? " · " + i18n("data from %1", U.ago(snapshot.fetchedAt, now)) : ""))
        return lines.join("\n")
    }
    toolTipTextFormat: Text.PlainText

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh Now")
            icon.name: "view-refresh"
            onTriggered: root.refresh(true)
        },
        PlasmaCore.Action {
            text: i18n("Open Usage Page")
            icon.name: "internet-web-browser"
            onTriggered: Qt.openUrlExternally("https://claude.ai/settings/usage")
        }
    ]

    onExpandedChanged: {
        if (expanded && (!snapshot || Date.now() - snapshot.fetchedAt > 45000)) refresh(false)
    }

    // MARK: - Credentials (~/.claude/.credentials.json, read-only)

    P5Support.DataSource {
        id: shell
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        property int serial: 0

        onNewData: (source, data) => {
            const cb = callbacks[source]
            delete callbacks[source]
            disconnectSource(source)
            if (cb) cb(data["exit code"], data["stdout"] || "")
        }

        function run(command, cb) {
            // A unique trailing comment lets the same command run again while an old one lingers.
            const source = command + " # " + (++serial)
            callbacks[source] = cb
            connectSource(source)
        }
    }

    readonly property string credentialCommand:
        'f="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.credentials.json}"; '
        + '[ -r "$f" ] || f="$HOME/.claude/.credentials.json"; cat "$f" 2>/dev/null'

    function loadCredential(force, cb) {
        if (!force && credential && !(credential.expiresAt && credential.expiresAt <= Date.now() + 60000)) {
            cb(null, credential)
            return
        }
        shell.run(credentialCommand, (code, stdout) => {
            const parsed = code === 0 ? U.parseCredential(stdout) : null
            if (!parsed) { cb(U.usageError("noCredentials"), null); return }
            credential = parsed
            credentialPlan = parsed.plan
            if (parsed.expiresAt && parsed.expiresAt <= Date.now()) { cb(U.usageError("credentialsExpired"), null); return }
            cb(null, parsed)
        })
    }

    // MARK: - Fetching (UsageAPI.swift)

    function fetchUsage(token, cb) {
        const xhr = new XMLHttpRequest()
        let done = false
        const finish = (err, result) => { if (!done) { done = true; abortTimer.stop(); cb(err, result) } }
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            const status = xhr.status
            if (status === 200) {
                try { finish(null, U.parseUsage(xhr.responseText, Date.now())) }
                catch (e) { finish(e.kind ? e : U.usageError("decoding", String(e)), null) }
            } else if (status === 401 || status === 403) {
                finish(U.usageError("unauthorized"), null)
            } else if (status === 429) {
                const e = U.usageError("rateLimited")
                const ra = Number(xhr.getResponseHeader("Retry-After"))
                e.retryAfter = isFinite(ra) && ra > 0 ? ra * 1000 : null
                finish(e, null)
            } else if (status === 0) {
                finish(U.usageError("network"), null)
            } else {
                finish(U.usageError("http", String(status)), null)
            }
        }
        xhr.open("GET", "https://api.anthropic.com/api/oauth/usage")
        xhr.setRequestHeader("Authorization", "Bearer " + token)
        xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20")
        xhr.setRequestHeader("Accept", "application/json")
        xhr.setRequestHeader("User-Agent", "claude-usage-widget/kde")
        abortTimer.onAbort = () => { xhr.abort(); finish(U.usageError("network", "timed out"), null) }
        abortTimer.restart()
        xhr.send()
    }

    Timer {
        id: abortTimer
        interval: 30000
        property var onAbort: null
        onTriggered: if (onAbort) onAbort()
    }

    /// The plan rarely changes, so ask the profile endpoint at most hourly. Failures are ignored.
    function fetchProfile(token) {
        if (Date.now() - profileFetchedAt < 3600 * 1000) return
        profileFetchedAt = Date.now()
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            const p = U.parseProfilePlan(xhr.responseText)
            if (p && p !== Plasmoid.configuration.cachedPlan) Plasmoid.configuration.cachedPlan = p
        }
        xhr.open("GET", "https://api.anthropic.com/api/oauth/profile")
        xhr.setRequestHeader("Authorization", "Bearer " + token)
        xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20")
        xhr.setRequestHeader("Accept", "application/json")
        xhr.setRequestHeader("User-Agent", "claude-usage-widget/kde")
        xhr.send()
    }

    function refresh(userInitiated) {
        if (refreshing) return
        if (!userInitiated && backoffUntil > Date.now()) return
        refreshing = true

        const fail = err => {
            error = U.errorInfo(err)
            if (err.kind === "rateLimited") backoffUntil = Date.now() + (err.retryAfter || 5 * 60 * 1000)
            refreshing = false
            now = Date.now()
        }
        const succeed = fresh => {
            if (credential) fetchProfile(credential.accessToken)
            snapshot = fresh
            error = null
            backoffUntil = 0
            Plasmoid.configuration.cachedSnapshot = JSON.stringify(fresh)
            refreshing = false
            now = Date.now()
        }

        loadCredential(false, (err, cred) => {
            if (err) { fail(err); return }
            fetchUsage(cred.accessToken, (err2, fresh) => {
                if (!err2) { succeed(fresh); return }
                if (err2.kind !== "unauthorized") { fail(err2); return }
                // Claude Code may have rotated the token since we read it. Re-read once.
                const oldToken = cred.accessToken
                loadCredential(true, (err3, cred2) => {
                    if (err3) { fail(err3); return }
                    if (cred2.accessToken === oldToken) { fail(err2); return }
                    fetchUsage(cred2.accessToken, (err4, fresh2) => err4 ? fail(err4) : succeed(fresh2))
                })
            })
        })
    }

    // MARK: - Timers

    Timer {
        id: pollTimer
        interval: root.refreshSeconds * 1000
        repeat: true
        running: true
        onTriggered: root.refresh(false)
    }

    Timer {
        // Keeps countdowns current, and notices resume from suspend (a big gap between ticks).
        interval: 30000
        repeat: true
        running: true
        onTriggered: {
            const t = Date.now()
            const slept = t - root.lastTick > 90000
            root.lastTick = t
            root.now = t
            if (slept) wakeTimer.restart()
        }
    }

    Timer {
        id: wakeTimer
        interval: 5000 // give the network a moment after resume
        onTriggered: root.refresh(false)
    }

    Component.onCompleted: {
        const cached = Plasmoid.configuration.cachedSnapshot
        if (cached) {
            try {
                const s = JSON.parse(cached)
                if (s && Array.isArray(s.limits)) snapshot = s
            } catch (e) {}
        }
        refresh(false)
    }
}
