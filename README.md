# LineLight

A traffic light for your internet line, sitting quietly in the macOS menu bar.

```
● 78      green  — line is fine
● 8.4     yellow — line is slow
● --      red    — line is down
```

LineLight runs a fast.com download test every 10 minutes and a lightweight ping
every minute. The dot takes the colour of whichever result is worse, and the
number next to it is the last speed reading in Mbps.

## Why

Speed test websites tell you how the line is *right now*, if you remember to
open one. LineLight just watches, so when a call drops or an upload stalls you
can glance up and see whether it was the line or something else.

## What it does

- **Speed** — downloads from Netflix's fast.com CDN targets in parallel for 8
  seconds and reports Mbps. Same infrastructure fast.com itself uses.
- **Ping** — ICMP to `1.1.1.1` (falls back to a TCP handshake if ICMP is
  blocked on your network).
- **Colour**

  | Colour | Meaning |
  |---|---|
  | 🟢 Green | ≥ 25 Mbps and ping ≤ 150 ms |
  | 🟡 Yellow | 5–25 Mbps, or ping above 150 ms, or speed test failed |
  | 🔴 Red | Unreachable, or under 5 Mbps |

- **Wake-aware** — re-checks immediately after the Mac wakes from sleep.
- **History** — the last 24 checks are listed under *Recent Checks*.

## Install

Requires macOS 12 or later and the Xcode Command Line Tools (the build script
offers to install them if they are missing).

```bash
git clone https://github.com/<your-user>/linelight.git
cd linelight
./build.sh --install
```

Or download the repo and double-click **Install LineLight.command** in Finder.

The app lands in `~/Applications/LineLight.app` and starts straight away. To
have it come back after a restart, open the menu and tick **Open at Login**.

Because the app is signed ad-hoc rather than with a paid Apple developer
certificate, Gatekeeper may complain the first time. Right-click the app in
Finder and choose *Open*, or run `xattr -dr com.apple.quarantine
~/Applications/LineLight.app`.

## Settings

Everything lives in the menu bar dropdown under **Settings**:

- Speed test interval — 5, 10, 15, 30 or 60 minutes
- Ping interval — 30 seconds to 5 minutes
- Menu bar display — speed, ping, or dot only

Thresholds and the ping host can be changed without rebuilding:

```bash
defaults write com.mok.linelight greenMbps  -float 50
defaults write com.mok.linelight yellowMbps -float 10
defaults write com.mok.linelight slowPingMs -float 120
defaults write com.mok.linelight pingHost   -string 8.8.8.8
defaults write com.mok.linelight testSeconds -float 10
```

Restart the app for those to take effect.

## Notes on accuracy

The reading is a download-only sample over a short window, so treat it as a
health indicator rather than a benchmark. It will read low if something else on
the machine is saturating the link, and a Wi-Fi reading tells you about the
Wi-Fi as much as about the line. For a proper measurement, open fast.com.

Each 8-second test moves roughly 25–100 MB depending on line speed. At the
default 10-minute interval that is a few GB a day, which is fine on an
unmetered connection — worth stretching the interval on a tethered one.

## Uninstall

```bash
pkill -x LineLight
rm -rf ~/Applications/LineLight.app
rm -f ~/Library/LaunchAgents/com.mok.linelight.plist
defaults delete com.mok.linelight
```

## Layout

```
Sources/
  main.swift              app entry point, menu-bar-only activation policy
  StatusController.swift  status item, menu, timers, colour logic
  SpeedTester.swift       fast.com token discovery + parallel download sample
  PingTester.swift        ICMP via /sbin/ping, TCP handshake fallback
  NetworkInfo.swift       Wi-Fi name, or the network service it falls back to
  SpeedChartView.swift    the speed-over-time graph drawn into the menu
  LinkWatcher.swift       fast drop detection — NWPathMonitor + a 3s TCP probe
  LaunchAtLogin.swift     LaunchAgent plist management
  Settings.swift          UserDefaults-backed preferences
Icon.png                  1024px source art; build.sh renders the .icns
build.sh                  compiles Sources/ into LineLight.app
```

No dependencies, no package manager, no Xcode project — `swiftc` and Cocoa.

## About

Built by **Mok Yii Chek**, together with **Claude** (Anthropic) — the design,
the Swift, and the debugging were worked out in conversation, then compiled and
installed on the machine it now watches.

It exists because a slow line and a busy Mac look the same from the outside, and
a coloured dot settles the question faster than opening a speed test.

## Licence

MIT © 2026 Mok Yii Chek
