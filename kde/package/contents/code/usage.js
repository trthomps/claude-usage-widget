.pragma library

// Port of Models.swift, UsageParser.swift and Formatting.swift.
// Plain JS so it can be unit-tested with node (see kde/test/parser.test.js).

var HOUR = 3600 * 1000;
var DAY = 24 * HOUR;

// MARK: - Severity

var Severity = { normal: 0, warning: 1, critical: 2, limited: 3 };

function severityForPercent(percent) {
    if (percent >= 100) return Severity.limited;
    if (percent >= 90) return Severity.critical;
    if (percent >= 75) return Severity.warning;
    return Severity.normal;
}

function severityFromServer(value) {
    if (!value) return null;
    switch (String(value).toLowerCase()) {
    case "warning": case "warn": case "approaching": case "elevated": case "high":
        return Severity.warning;
    case "critical": case "danger": case "severe":
        return Severity.critical;
    case "limited": case "exceeded": case "blocked": case "at_limit": case "maxed": case "locked":
        return Severity.limited;
    default:
        return null;
    }
}

function severity(limit) {
    var server = severityFromServer(limit.serverSeverity);
    return Math.max(severityForPercent(limit.percent), server === null ? 0 : server);
}

// MARK: - Limit naming

function humanize(raw) {
    var words = String(raw).split(/[_-]/).filter(function (w) { return w.length > 0; });
    if (words.length === 0) return raw;
    var first = words[0].charAt(0).toUpperCase() + words[0].slice(1).toLowerCase();
    return [first].concat(words.slice(1)).join(" ");
}

function windowDuration(kind, group) {
    var k = String(kind).toLowerCase(), g = String(group).toLowerCase();
    if (g === "session" || k.indexOf("session") >= 0 || k.indexOf("five_hour") >= 0) return 5 * HOUR;
    if (g === "weekly" || k.indexOf("weekly") >= 0 || k.indexOf("seven_day") === 0) return 7 * DAY;
    if (g === "daily" || k.indexOf("daily") >= 0) return DAY;
    return null;
}

function describe(kind, group, scope) {
    var duration = windowDuration(kind, group);
    scope = scope ? String(scope).trim() : "";

    if (!scope) {
        if (kind === "session")
            return { id: "session", title: "Current session", short: "5h", widgetTitle: "Session",
                     duration: duration || 5 * HOUR };
        if (kind === "weekly_all")
            return { id: "weekly_all", title: "Current week (all models)", short: "7d", widgetTitle: "Week",
                     duration: duration || 7 * DAY };
        var name = humanize(kind);
        return { id: kind, title: name, short: name.slice(0, 2), widgetTitle: name, duration: duration };
    }

    var slug = scope.toLowerCase().replace(/ /g, "_");
    var initial = scope.charAt(0).toUpperCase();
    if (group === "weekly" || kind.indexOf("weekly") === 0 || kind.indexOf("seven_day") === 0)
        return { id: "weekly:" + slug, title: "Current week (" + scope + ")", short: initial,
                 widgetTitle: scope, duration: duration || 7 * DAY };
    return { id: kind + ":" + slug, title: humanize(kind) + " (" + scope + ")", short: initial,
             widgetTitle: scope, duration: duration };
}

function makeLimit(kind, group, scope, percent, resetsAt, serverSeverity, isActive) {
    var info = describe(kind, group, scope);
    return {
        id: info.id, kind: kind, group: group, title: info.title, shortLabel: info.short,
        widgetTitle: info.widgetTitle, percent: percent,
        resetsAt: resetsAt,               // ms since epoch, or null
        windowDuration: info.duration,    // ms, or null
        serverSeverity: serverSeverity || null, isActive: !!isActive
    };
}

// MARK: - Parsing GET /api/oauth/usage

function number(v) {
    if (typeof v === "number") return isFinite(v) ? v : null;
    if (typeof v === "string" && v.trim() !== "") {
        var n = Number(v);
        return isFinite(n) ? n : null;
    }
    return null;
}

/// Milliseconds since epoch, or null. Accepts seconds, ms, or ISO-8601 with any fraction.
function parseDate(v) {
    var n = number(v);
    if (n !== null) return n > 1e12 ? n : n * 1000;
    if (typeof v !== "string" || v === "") return null;
    // V4's Date parser is picky about microseconds ("…:00.076612+00:00"); drop the fraction.
    var trimmed = v.replace(/\.\d+/, "").replace(/([+-]\d\d)(\d\d)$/, "$1:$2");
    var t = Date.parse(trimmed);
    return isNaN(t) ? null : t;
}

function scopeName(any) {
    if (typeof any === "string") return any || null;
    if (!any || typeof any !== "object") return null;
    var keys = ["model", "surface", "product", "feature"];
    for (var i = 0; i < keys.length; i++) {
        var value = any[keys[i]];
        if (typeof value === "string" && value) return value;
        if (value && typeof value === "object") {
            var nameKeys = ["display_name", "name", "id"];
            for (var j = 0; j < nameKeys.length; j++) {
                if (typeof value[nameKeys[j]] === "string" && value[nameKeys[j]]) return value[nameKeys[j]];
            }
        }
    }
    return typeof any.display_name === "string" ? any.display_name : null;
}

function inferredGroup(kind) {
    if (kind.indexOf("session") >= 0) return "session";
    if (kind.indexOf("week") >= 0) return "weekly";
    return "";
}

function parseLimit(entry) {
    if (!entry || typeof entry !== "object") return null;
    var percent = number(entry.percent);
    if (percent === null) percent = number(entry.utilization);
    if (percent === null) return null;
    var kind = typeof entry.kind === "string" ? entry.kind : "limit";
    var group = typeof entry.group === "string" ? entry.group : "";
    var limit = makeLimit(kind, group, scopeName(entry.scope), percent, parseDate(entry.resets_at),
                          typeof entry.severity === "string" ? entry.severity : null,
                          entry.is_active === true);
    if (!group) limit.group = inferredGroup(kind);
    return limit;
}

function legacyOrder(key) {
    if (key === "five_hour") return "0";
    if (key === "seven_day") return "1";
    return "2" + key;
}

function parseLegacy(root) {
    var keys = Object.keys(root)
        .filter(function (k) { return k === "five_hour" || k.indexOf("seven_day") === 0; })
        .sort(function (a, b) { var x = legacyOrder(a), y = legacyOrder(b); return x < y ? -1 : x > y ? 1 : 0; });

    var out = [];
    keys.forEach(function (key) {
        var entry = root[key];
        if (!entry || typeof entry !== "object") return;
        var percent = number(entry.utilization);
        if (percent === null) percent = number(entry.percent);
        if (percent === null) return;
        var kind, group, scope = null;
        if (key === "five_hour") { kind = "session"; group = "session"; }
        else if (key === "seven_day") { kind = "weekly_all"; group = "weekly"; }
        else {
            kind = "weekly_scoped"; group = "weekly";
            var raw = key.slice("seven_day_".length);
            scope = raw === "oauth_apps" ? "OAuth apps" : humanize(raw);
        }
        out.push(makeLimit(kind, group, scope, percent, parseDate(entry.resets_at), null, false));
    });
    return out;
}

function money(any) {
    if (!any || typeof any !== "object") return null;
    var minor = number(any.amount_minor);
    if (minor === null) return null;
    var exp = number(any.exponent);
    return minor / Math.pow(10, exp === null ? 2 : exp);
}

function parseExtra(root) {
    if (root.spend && typeof root.spend === "object") {
        var used = money(root.spend.used);
        if (used !== null) {
            return { used: used, limit: money(root.spend.limit),
                     currency: (root.spend.used && root.spend.used.currency) || "USD",
                     enabled: root.spend.enabled === true };
        }
    }
    var extra = root.extra_usage;
    if (extra && typeof extra === "object") {
        var places = number(extra.decimal_places);
        var scale = Math.pow(10, places === null ? 2 : places);
        var monthly = number(extra.monthly_limit);
        return { used: (number(extra.used_credits) || 0) / scale,
                 limit: monthly === null ? null : monthly / scale,
                 currency: extra.currency || "USD", enabled: extra.is_enabled === true };
    }
    return null;
}

/// Returns { limits, extra, fetchedAt } or throws an Error with .kind = "decoding".
function parseUsage(text, fetchedAt) {
    var root;
    try { root = JSON.parse(text); } catch (e) { throw usageError("decoding", "invalid JSON"); }
    if (!root || typeof root !== "object" || Array.isArray(root))
        throw usageError("decoding", "expected a JSON object");

    var limits;
    if (Array.isArray(root.limits) && root.limits.length > 0)
        limits = root.limits.map(parseLimit).filter(function (l) { return l !== null; });
    else
        limits = parseLegacy(root);

    var seen = {};
    limits.forEach(function (l) {
        if (seen[l.id]) { seen[l.id] += 1; l.id = l.id + "#" + seen[l.id]; }
        else seen[l.id] = 1;
    });

    if (limits.length === 0 && root.limits === undefined && root.five_hour === undefined)
        throw usageError("decoding", "no usage limits in response");

    return { limits: limits, extra: parseExtra(root), fetchedAt: fetchedAt || Date.now() };
}

// MARK: - Credentials (~/.claude/.credentials.json)

function parseCredential(text) {
    var root;
    try { root = JSON.parse(text); } catch (e) { return null; }
    if (!root || typeof root !== "object") return null;
    var oauth = root.claudeAiOauth || root;
    if (typeof oauth.accessToken !== "string" || !oauth.accessToken) return null;
    var exp = number(oauth.expiresAt);
    return {
        accessToken: oauth.accessToken,
        expiresAt: exp === null ? null : (exp > 1e12 ? exp : exp * 1000),
        plan: planDescription(oauth.subscriptionType, oauth.rateLimitTier)
    };
}

/// "Max · 20x", "Team · 5x", "Pro".
function planDescription(subscriptionType, tier) {
    if (!subscriptionType) return "";
    var raw = String(subscriptionType).toLowerCase();
    var names = { pro: "Pro", max: "Max", team: "Team", enterprise: "Enterprise", free: "Free" };
    var base = names[raw] || (raw.charAt(0).toUpperCase() + raw.slice(1));
    var m = tier ? String(tier).match(/\d+x/) : null;
    return m ? base + " · " + m[0] : base;
}

/// Plan from GET /api/oauth/profile. Preferred over the credentials file, whose
/// rateLimitTier is only written at login and goes stale after a plan change.
function parseProfilePlan(text) {
    var root;
    try { root = JSON.parse(text); } catch (e) { return null; }
    var org = root && root.organization;
    if (!org || typeof org !== "object") return null;
    // The server's own name for the plan ("Ultra"), when it sends one.
    if (typeof org.plan_display_name === "string" && org.plan_display_name.trim())
        return org.plan_display_name.trim();
    var type = typeof org.organization_type === "string" ? org.organization_type.replace(/^claude_/, "") : "";
    if (!type) return null;
    return planDescription(type, org.rate_limit_tier);
}

// MARK: - Errors

var errorText = {
    noCredentials: ["Not signed in",
        "No Claude Code login found. Run \"claude\" in a terminal and sign in with your Claude account."],
    credentialsExpired: ["Login expired",
        "Claude Code's login token has expired. It renews the next time you use Claude Code, and usage updates then."],
    unauthorized: ["Login rejected",
        "Anthropic rejected the saved login. Run /login in Claude Code to sign in again."],
    rateLimited: ["Rate limited", "The usage API is rate limiting requests. Retrying later."],
    http: ["Server error", "The usage API returned an error. Retrying automatically."],
    network: ["Offline", "Couldn't reach Anthropic."],
    decoding: ["Unexpected response", "Couldn't read the usage response."]
};

var errorIcon = {
    noCredentials: "user-identity", unauthorized: "user-identity",
    credentialsExpired: "chronometer", rateLimited: "chronometer",
    network: "network-disconnect", http: "dialog-warning", decoding: "dialog-warning"
};

function usageError(kind, detail) {
    var e = new Error(detail || kind);
    e.kind = kind;
    e.detail = detail || "";
    return e;
}

function errorInfo(err) {
    if (!err) return null;
    var kind = err.kind || "network";
    var t = errorText[kind] || errorText.network;
    var title = t[0], message = t[1];
    if (kind === "http" && err.detail) title = "Server error " + err.detail;
    if (kind === "rateLimited" && err.retryAfter)
        message = "The usage API is rate limiting requests. Retrying in " + duration(err.retryAfter) + ".";
    if ((kind === "network" || kind === "decoding") && err.detail) message += " (" + err.detail + ")";
    return { kind: kind, title: title, message: message, icon: errorIcon[kind] || "dialog-warning" };
}

// MARK: - Time math

/// The limit as of `now`. Once the reset passes, show 0% until the next fetch lands.
function effective(limit, now) {
    if (limit.resetsAt === null || limit.resetsAt > now) return limit;
    var copy = {};
    for (var k in limit) copy[k] = limit[k];
    copy.percent = 0;
    copy.serverSeverity = null;
    if (limit.group === "weekly" && limit.windowDuration > 0) {
        var next = limit.resetsAt;
        while (next <= now) next += limit.windowDuration;
        copy.resetsAt = next;
    } else {
        copy.resetsAt = null; // a new session only starts with your next message
    }
    return copy;
}

/// How far through the window we are, 0…1 (where even usage would sit).
function elapsedFraction(limit, now) {
    if (limit.resetsAt === null || !(limit.windowDuration > 0)) return null;
    var start = limit.resetsAt - limit.windowDuration;
    var f = (now - start) / limit.windowDuration;
    if (!isFinite(f)) return null;
    return Math.min(Math.max(f, 0), 1);
}

/// { runsOutIn: ms } or { endsAt: percent } or null.
function forecast(limit, now) {
    if (limit.percent < 1 || limit.percent >= 100 || limit.resetsAt === null) return null;
    var f = elapsedFraction(limit, now);
    if (f === null) return null;
    var elapsed = f * limit.windowDuration;
    if (elapsed < 15 * 60 * 1000) return null;
    var rate = limit.percent / elapsed;
    var remaining = limit.resetsAt - now;
    if (remaining <= 0) return null;
    var projected = limit.percent + rate * remaining;
    if (projected >= 100) return { runsOutIn: (100 - limit.percent) / rate };
    return { endsAt: projected };
}

/// The limit closest to blocking you: highest severity, then highest percent.
function mostPressing(limits) {
    var best = null;
    limits.forEach(function (l) {
        if (!best) { best = l; return; }
        var a = severity(l), b = severity(best);
        if (a > b || (a === b && l.percent > best.percent)) best = l;
    });
    return best;
}

/// Filters limits by a list of ids. "weekly:*" matches every per-model weekly limit.
function selectLimits(limits, metrics) {
    var picked = limits.filter(function (l) {
        var base = l.id.split("#")[0];
        return metrics.indexOf(base) >= 0 || (base.indexOf("weekly:") === 0 && metrics.indexOf("weekly:*") >= 0);
    });
    return picked.length > 0 ? picked : limits.slice(0, 2);
}

// MARK: - Formatting

function percentText(v) {
    return Math.round(Math.min(Math.max(v, 0), 999)) + "%";
}

/// style: "long" ("2h 14m"), "compact" ("2h14m"), "tiny" ("2h").
function duration(ms, style) {
    style = style || "long";
    var total = Math.max(0, Math.floor(ms / 1000));
    if (total < 60) return "<1m";
    var days = Math.floor(total / 86400);
    var hours = Math.floor((total % 86400) / 3600);
    var totalHours = Math.floor(total / 3600);
    var minutes = Math.floor((total % 3600) / 60);
    var sep = style === "long" ? " " : "";
    if (style === "tiny") {
        if (days > 0) return days + "d";
        if (totalHours > 0) return totalHours + "h";
        return minutes + "m";
    }
    if (days > 0) return hours > 0 ? days + "d" + sep + hours + "h" : days + "d";
    if (style === "compact" && totalHours >= 10) return totalHours + "h";
    if (totalHours > 0) return minutes > 0 ? totalHours + "h" + sep + minutes + "m" : totalHours + "h";
    return minutes + "m";
}

/// formatTime / formatDayTime are passed in from QML so the user's locale is used.
function resetPhrase(limit, now, formatTime, formatDayTime) {
    if (limit.resetsAt === null)
        return limit.group === "session" ? "Starts with your next message" : "Not started";
    var remaining = limit.resetsAt - now;
    if (remaining <= 0) return "Resetting…";
    var at = new Date(limit.resetsAt);
    if (remaining < DAY) return "Resets in " + duration(remaining) + " · " + formatTime(at);
    return "Resets " + formatDayTime(at) + " · in " + duration(remaining);
}

function ago(t, now) {
    var s = (now - t) / 1000;
    if (s < 60) return "just now";
    if (s < 3600) return Math.floor(s / 60) + "m ago";
    if (s < 86400) return Math.floor(s / 3600) + "h ago";
    return Math.floor(s / 86400) + "d ago";
}

function moneyText(value, currency) {
    var symbols = { USD: "$", EUR: "€", GBP: "£", JPY: "¥", CAD: "CA$", AUD: "A$" };
    var s = symbols[currency];
    return s ? s + value.toFixed(2) : value.toFixed(2) + " " + currency;
}
