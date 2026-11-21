import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import QtCore

import "../code/usage.js" as U

PlasmoidItem {
    id: root

    // MARK: - State (UsageStore.swift)

    property var snapshot: null          // { limits, extra, fetchedAt }
    property var error: null             // U.errorInfo(...)
    property string credentialPlan: ""
    // The profile's plan name is trusted only for the login it was fetched under, so switching
    // accounts never shows the previous account's plan.
    readonly property var planCache: {
        try { return cache.plan ? JSON.parse(cache.plan) : null } catch (e) { return null }
    }
    readonly property string plan: planCache && planCache.plan
        && (!credential || planCache.login === credential.login) ? planCache.plan : credentialPlan
    property string profileToken: ""      // token the cached plan was last confirmed with
    property real profileNextAt: 0        // earliest time for the next profile request
    property bool profileBusy: false
    property real cacheWrittenAt: 0
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
        if (root.expanded && (!snapshot || Date.now() - snapshot.fetchedAt > 45000)) refresh(false)
    }

    // MARK: - Cache (~/.cache/plasmashell/claude-usage-widget.conf)

    // Kept out of Plasma's layout config so polling doesn't rewrite appletsrc. Holds the last
    // good snapshot (percentages and reset times) and the plan name; never the token.
    Settings {
        id: cache
        location: StandardPaths.writableLocation(StandardPaths.CacheLocation) + "/claude-usage-widget.conf"
        category: "Cache"
        property string snapshot: ""
        property string plan: ""
    }

    // MARK: - Credentials (~/.claude/.credentials.json, read-only)

    P5Support.DataSource {
        id: shell
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        property int serial: 0

        onNewData: (source, data) => finish(source, data["exit code"], data["stdout"] || "")

        function finish(source, code, stdout) {
            const pending = callbacks[source]
            delete callbacks[source]
            disconnectSource(source)
            if (Object.keys(callbacks).length === 0) shellWatchdog.stop()
            if (pending) pending.cb(code, stdout)
        }

        function run(command, cb) {
            // A unique trailing comment lets the same command run again while an old one lingers.
            const source = command + " # " + (++serial)
            callbacks[source] = { cb: cb, at: Date.now() }
            shellWatchdog.start()
            connectSource(source)
        }
    }

    Timer {
        // If the executable engine never answers, fail the read instead of wedging `refreshing`.
        id: shellWatchdog
        interval: 2000
        repeat: true
        onTriggered: {
            const cutoff = Date.now() - 10000
            Object.keys(shell.callbacks).forEach(source => {
                if (shell.callbacks[source].at < cutoff) shell.finish(source, -1, "")
            })
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
        // Report the timeout before abort(): abort() fires readystatechange with status 0.
        abortTimer.onAbort = () => { finish(U.usageError("network", "timed out"), null); xhr.abort() }
        abortTimer.restart()
        xhr.send()
    }

    Timer {
        id: abortTimer
        interval: 30000
        property var onAbort: null
        onTriggered: if (onAbort) onAbort()
    }

    /// The plan rarely changes, so ask the profile endpoint hourly, or right away when the login
    /// changes. A failure retries in 5 minutes. It's cosmetic, so errors never surface.
    function fetchProfile(cred) {
        if (profileBusy || (cred.accessToken === profileToken && Date.now() < profileNextAt)) return
        profileBusy = true
        const xhr = new XMLHttpRequest()
        let done = false
        const finish = planName => {
            if (done) return
            done = true
            profileTimeout.stop()
            profileBusy = false
            profileToken = cred.accessToken
            profileNextAt = Date.now() + (planName ? 3600 : 5 * 60) * 1000
            if (planName) {
                const entry = JSON.stringify({ plan: planName, login: cred.login })
                if (entry !== cache.plan) cache.plan = entry
            }
        }
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            finish(xhr.status === 200 ? U.parseProfilePlan(xhr.responseText) : null)
        }
        xhr.open("GET", "https://api.anthropic.com/api/oauth/profile")
        xhr.setRequestHeader("Authorization", "Bearer " + cred.accessToken)
        xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20")
        xhr.setRequestHeader("Accept", "application/json")
        profileTimeout.onAbort = () => { finish(null); xhr.abort() }
        profileTimeout.restart()
        xhr.send()
    }

    Timer {
        id: profileTimeout
        interval: 15000
        property var onAbort: null
        onTriggered: if (onAbort) onAbort()
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
            // Only touch the cache file when the numbers change, or to keep fetchedAt
            // roughly current for the stale check after a restart.
            const changed = !snapshot
                || JSON.stringify([snapshot.limits, snapshot.extra]) !== JSON.stringify([fresh.limits, fresh.extra])
            if (changed || fresh.fetchedAt - cacheWrittenAt > 10 * 60 * 1000) {
                cache.snapshot = JSON.stringify(fresh)
                cacheWrittenAt = fresh.fetchedAt
            }
            snapshot = fresh
            error = null
            backoffUntil = 0
            refreshing = false
            now = Date.now()
            if (credential) fetchProfile(credential)
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
        const cached = cache.snapshot
        if (cached) {
            try {
                const s = JSON.parse(cached)
                if (s && Array.isArray(s.limits)) { snapshot = s; cacheWrittenAt = s.fetchedAt || 0 }
            } catch (e) {}
        }
        refresh(false)
    }
}
