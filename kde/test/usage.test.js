// Run: node kde/test/usage.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert");
const src = fs.readFileSync(path.join(__dirname, "../package/contents/code/usage.js"), "utf8")
    .replace(/^\.pragma library.*$/m, "");
const U = {};
vm.runInNewContext(src + "\nObject.assign(U, this);", { U });

const now = Date.parse("2026-11-21T12:00:00Z");
let pass = 0;
// Objects come from another VM realm, so compare by value.
const eq = (a, b) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b));
function test(name, fn) { fn(); pass++; }

test("structured limits", () => {
    const s = U.parseUsage(JSON.stringify({
        limits: [
            { kind: "session", group: "session", percent: 37, resets_at: "2026-11-21T15:49:00.076612+00:00" },
            { kind: "weekly_all", group: "weekly", percent: 17, resets_at: "2026-11-26T06:59:00Z" },
            { kind: "weekly_scoped", group: "weekly", scope: { model: { display_name: "Fable" } }, percent: 0 },
            { kind: "weekly_scoped", group: "weekly", scope: "Fable", percent: 1 },
            { kind: "junk" },
        ],
        spend: { used: { amount_minor: 1240, exponent: 2, currency: "USD" }, limit: { amount_minor: 20000 }, enabled: true },
    }), now);
    eq(s.limits.map(l => l.id), ["session", "weekly_all", "weekly:fable", "weekly:fable#2"]);
    assert.strictEqual(s.limits[0].title, "Current session");
    assert.strictEqual(s.limits[0].resetsAt, Date.parse("2026-11-21T15:49:00Z"));
    assert.strictEqual(s.limits[2].title, "Current week (Fable)");
    assert.strictEqual(s.limits[2].shortLabel, "F");
    eq(s.extra, { used: 12.4, limit: 200, currency: "USD", enabled: true });
});

test("legacy flat keys", () => {
    const s = U.parseUsage(JSON.stringify({
        seven_day_opus: { utilization: 3, resets_at: null },
        five_hour: { utilization: 50, resets_at: "2026-11-21T14:00:00+00:00" },
        seven_day: { utilization: "12.5", resets_at: 1795000000 },
        seven_day_oauth_apps: { utilization: 0 },
        extra_usage: { is_enabled: true, used_credits: 500, monthly_limit: 10000, currency: "EUR" },
    }), now);
    eq(s.limits.map(l => l.title), ["Current session", "Current week (all models)",
        "Current week (OAuth apps)", "Current week (Opus)"]);
    assert.strictEqual(s.limits[1].percent, 12.5);
    assert.strictEqual(s.limits[1].resetsAt, 1795000000000);
    eq(s.extra, { used: 5, limit: 100, currency: "EUR", enabled: true });
});

test("errors", () => {
    assert.throws(() => U.parseUsage("nope"), e => e.kind === "decoding");
    assert.throws(() => U.parseUsage("{}"), e => e.kind === "decoding");
    assert.strictEqual(U.parseUsage('{"limits":[]}').limits.length, 0);
});

test("credentials", () => {
    const c = U.parseCredential(JSON.stringify({ claudeAiOauth: {
        accessToken: "tok", expiresAt: 1795000000000, subscriptionType: "max", rateLimitTier: "default_claude_max_5x" } }));
    eq(c, { accessToken: "tok", expiresAt: 1795000000000, plan: "Max · 5x" });
    assert.strictEqual(U.parseCredential("{}"), null);
    assert.strictEqual(U.planDescription("team", null), "Team");
});

test("rollover, pace, forecast", () => {
    const session = U.makeLimit("session", "session", null, 40, now + 3 * 3600e3, null, false);
    assert.ok(Math.abs(U.elapsedFraction(session, now) - 0.4) < 1e-9);
    // 40% used in 2h of a 5h window → 100% in another 3h → exactly at reset
    const f = U.forecast(session, now);
    assert.ok(f.runsOutIn !== undefined && Math.abs(f.runsOutIn - 3 * 3600e3) < 1);
    const slower = U.makeLimit("session", "session", null, 20, now + 3 * 3600e3, null, false);
    assert.ok(Math.abs(U.forecast(slower, now).endsAt - 50) < 1e-9);

    const expired = U.effective(U.makeLimit("session", "session", null, 80, now - 1000, null, false), now);
    assert.strictEqual(expired.percent, 0);
    assert.strictEqual(expired.resetsAt, null);
    const week = U.effective(U.makeLimit("weekly_all", "weekly", null, 80, now - 1000, "critical", false), now);
    assert.strictEqual(week.resetsAt, now - 1000 + 7 * 86400e3);
    assert.strictEqual(U.severity(week), U.Severity.normal);
});

test("profile plan", () => {
    assert.strictEqual(U.parseProfilePlan(JSON.stringify({ organization: {
        organization_type: "claude_max", rate_limit_tier: "default_claude_max_20x" } })), "Max · 20x");
    assert.strictEqual(U.parseProfilePlan(JSON.stringify({ organization: { organization_type: "claude_team" } })), "Team");
    assert.strictEqual(U.parseProfilePlan(JSON.stringify({ organization: { plan_display_name: "Ultra",
        organization_type: "claude_max", rate_limit_tier: "default_claude_max_20x" } })), "Ultra");
    assert.strictEqual(U.parseProfilePlan("{}"), null);
    assert.strictEqual(U.parseProfilePlan("nope"), null);
});

test("severity", () => {
    assert.strictEqual(U.severity({ percent: 76 }), U.Severity.warning);
    assert.strictEqual(U.severity({ percent: 10, serverSeverity: "exceeded" }), U.Severity.limited);
    assert.strictEqual(U.mostPressing([{ percent: 10 }, { percent: 80 }, { percent: 50 }]).percent, 80);
});

test("formatting", () => {
    assert.strictEqual(U.duration(30e3), "<1m");
    assert.strictEqual(U.duration((2 * 3600 + 14 * 60) * 1e3), "2h 14m");
    assert.strictEqual(U.duration((2 * 3600 + 14 * 60) * 1e3, "compact"), "2h14m");
    assert.strictEqual(U.duration(13 * 3600e3 + 60e3, "compact"), "13h");
    assert.strictEqual(U.duration((5 * 86400 + 16 * 3600) * 1e3), "5d 16h");
    assert.strictEqual(U.duration((5 * 86400 + 16 * 3600) * 1e3, "tiny"), "5d");
    assert.strictEqual(U.percentText(36.6), "37%");
    assert.strictEqual(U.ago(now - 125e3, now), "2m ago");
    assert.strictEqual(U.moneyText(12.4, "USD"), "$12.40");
});

test("selectLimits", () => {
    const ls = [{ id: "session" }, { id: "weekly_all" }, { id: "weekly:fable" }, { id: "weekly:fable#2" }];
    eq(U.selectLimits(ls, ["session"]).map(l => l.id), ["session"]);
    eq(U.selectLimits(ls, ["weekly:*"]).map(l => l.id), ["weekly:fable", "weekly:fable#2"]);
    assert.strictEqual(U.selectLimits(ls, []).length, 2);
});

console.log(`${pass} tests passed`);
