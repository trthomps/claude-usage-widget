# Claude Usage for KDE Plasma 6

A Plasma 6 widget (plasmoid) port of the macOS app: the same limits, pace marker, forecast and colors, in QML/Qt 6.

- **In a panel**: pills (or stacked / focus / text, same as the macOS menu bar styles). Click for the detail popup, middle-click to refresh, right-click for Refresh Now and Open Usage Page.
- **On the desktop**: a ring per limit, like the macOS desktop widget.
- **Tooltip**: every limit with its reset time.

## Install

Requires Plasma 6 and a Claude Code login on this machine (`claude`, then `/login`).

```sh
make kde-install    # or: kpackagetool6 -t Plasma/Applet -i kde/package
```

Then right-click a panel or the desktop → **Add Widgets…** → **Claude Usage**. Settings are in the widget's **Configure…** dialog.

After upgrading an installed copy, restart Plasma so it reloads the QML: `systemctl --user restart plasma-plasmashell`. To try it in a window without touching your panel: `plasmawindowed dev.claudeusage.plasmoid`.

## How it differs from the macOS version

- **Login**: reads `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`), which is where Claude Code keeps its login on Linux. The file is read with `cat` through Plasma's executable data engine, since QML can't read local files directly. The token stays in memory; it's never written anywhere and never refreshed.
- **Cache**: the last good snapshot (percentages and reset times only) is stored in the widget's own config entry, in `~/.config/plasma-org.kde.plasma.desktop-appletsrc`.
- **Colors** follow the Plasma theme: *Warnings* uses the theme's neutral (orange) and negative (red) colors.
- **Resume from suspend** is detected from a gap between clock ticks and triggers a refresh 5 seconds later.

## Files

| File | What's in it |
| --- | --- |
| `package/contents/code/usage.js` | Parser, limit naming, pace/forecast math, formatting. A port of `Models.swift`, `UsageParser.swift`, `Formatting.swift`. |
| `package/contents/ui/main.qml` | State, credential loading, fetching, polling, backoff, cache |
| `package/contents/ui/CompactRepresentation.qml`, `Pill.qml` | Panel item |
| `package/contents/ui/PopupView.qml`, `LimitRow.qml`, `UsageBar.qml` | Detail popup |
| `package/contents/ui/DesktopView.qml`, `RingGauge.qml` | Desktop widget |
| `package/contents/ui/configGeneral.qml`, `package/contents/config/main.xml` | Settings |

`make kde-test` runs the parser and formatting tests under Node.
