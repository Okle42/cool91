# cool91 — temperature / fan / clock monitor for Apple Silicon, plus a gatekeeper that stops AI agents from cooking your Mac

[繁體中文](README.md)

> A menu-bar panel that shows CPU / GPU temperature, every core's own sensor (73 on an M4, as a heat grid), fan RPM, the P-cores' **actual** clock and whether macOS is quietly throttling you. Custom fan curves, overheat / cooled-down chimes with adjustable thresholds.
> Then the part no other monitor has: **when an AI agent like Claude Code runs heavy work on your Mac, let the machine go full speed, let the fan prevent throttling, and only make the work wait when throttling actually happens.**
> Whole stack idles at **0.3% CPU / 10 MB** (guard 0.1% + clock reader 0.18%); the panel 0.2% idle, 0–3% open.

**Two ways to use it, one install:**

| | What you get |
|---|---|
| **Just a monitor + fan controller** (no Claude Code needed) | Things Apple doesn't tell you: what the P-cores are really clocked at right now, when throttling starts, which core is hottest, whether the GPU is being capped. Fan modes curve / fixed / auto, edited live from the panel, with quiet / balanced / strong presets |
| **A gatekeeper for AI agents** | Claude Code asks before launching heavy commands (hook + MCP), waits only when really throttled, spins the fan up *before* `swift build` / `blender` / `ffmpeg`, and daily stats tell you whether your curve is right |

**In plain words**: Apple's fan policy is silence-first. The CPU hits 100 °C before the fan really ramps, then the CPU quietly slows itself 15–25% and you never know. cool91 first makes that **visible** (the panel's first line says "full speed · not throttled" or "throttling"), then flips the policy: run the fan at the lowest speed that avoids throttling (measured on an M4 mini: 87 °C / 3150 rpm), and have Claude Code wait only when throttling really happens. It also survives the moments the machine is busiest — learned the hard way, see problem 15 below.

![Mac mini M4](https://img.shields.io/badge/tested-Mac%20mini%20M4-blue) ![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![deps](https://img.shields.io/badge/dependencies-0-brightgreen) ![license](https://img.shields.io/badge/license-MIT-green)

---

## Why

It started with wanting to *see*. I hand a lot of engineering work to Claude Code: several agents building, computing geometry, generating 3D models at once. One day I looked at the temperature:

```
CPU 105°C   fan 1774 rpm (macOS auto)
```

The Mac mini M4's stock fan policy is extremely conservative — **CPU already at 100 °C, fan still loafing around 1400 rpm** — and the P-cores silently drop from 4.4 GHz to 3.3–3.8 GHz with no indication. Existing monitors and fan tools can show temperature and raise the curve, but:

1. **They don't know whether you're throttled** — they watch temperature, not hardware clocks; many of them read the PMU temperature on M4, which sits 15–20 °C below the cores (problem 14)
2. **GUI only, no CLI, no API** — an AI agent can't ask "is it OK to start now?"
3. **They're all resident GUI apps** — heavy for something that reads a handful of SMC keys

I wanted something that **sees the truth** (hardware clocks, per-core temperatures), **can be called from a script**, **plugs into a Claude Code hook**, and **costs almost nothing**. That's cool91.

## Features

**Monitoring and fan control (for anyone)**

| | cool91 | typical monitor / fan tool |
|---|---|---|
| Menu bar | ✅ `🟡 82°`; click for temperature / fan / clock cards with 5-minute charts | ✅ |
| **Per-core temperature** | ✅ heat grid: P-core / E-core / GPU groups, 73 SMC sensors on M4, hover for value | partial (usually averages or PMU) |
| **Hardware clock / thermal throttling detection** | ✅ P-core GHz, thermal pressure; panel / statusline turn red, logged | ❌ |
| **GPU utilisation / GPU throttling** | ✅ IOReport utilisation and clock, `GPU_CLTM` detection | ❌ |
| Custom fan curve | ✅ curve / fixed / auto, live edit from the panel, hot-reload on save | ✅ |
| CPU + GPU together | ✅ max of both drives the fan | ✅ |
| No fan hunting | ✅ fast up, slow down, max −300 rpm per 5 s | partial |
| Chimes | ✅ overheat / throttled and cooled-down, bundled sounds replaceable, thresholds adjustable in the panel | partial |
| **Who's computing right now** | ✅ `cool91 top` / one line in the panel: top CPU commands with working directory | ❌ |
| Daily stats | ✅ seconds throttled, seconds hot / critical, peak — one number tells you if the curve is right | ❌ |
| Resident cost | **0.3% CPU / 10 MB** (measured) | usually tens of MB |
| Dependencies | **0** (pure Swift + 80 lines of C, builds with SwiftPM) | mostly closed source |
| New chips (M5 / M6…) | sensors are scanned dynamically; change a prefix in config | wait for the author |
| License | MIT | mostly closed source |

**For AI agents (unique to cool91)**

| | |
|---|---|
| **Gate hook** | Claude Code PreToolUse hook: **waits only when actually throttled**; hot-but-not-throttled runs; denies only on Trapping or ≥ critical |
| **MCP server** | 7 tools so the AI can check status, decide whether to start, wait for cool-down, see who's eating CPU, switch fan mode |
| **Pre-warm for heavy commands** | fan ramps before `swift build` / `blender` / `ffmpeg`… |
| CLI for scripts | `cool91 check` returns exit code 0 / 1 / 2 |
| Survives heavy load | Standard QoS + watchdog; keeps the fan speed across restarts |
| Statusline snippet | Claude Code statusline shows `🌡85°🌀4896⚡3.9G`, ⚡ turns red when throttled |

## Architecture

```
AppleSMC (IOKit)                        powermetrics (root)
   │                                        │
   ▼                                        │
Sources/CSMC          80 lines of C: open / read / write / enumerate keys
   │                                        │
   ▼                                        ▼
Sources/Cool91Core    Swift library: type decoding, sensor scan, fan curve, config, snapshot, clock reader, events
   │
   ├─► cool91 (CLI)
   │     ├─ guard   root LaunchDaemon; every 5 s writes F0Tg/F0Md from the curve
   │     │          keeps one powermetrics child for P/E-core hardware clocks and thermal pressure
   │     │          writes /tmp/cool91.json (snapshot + clocks + daily stats), /tmp/cool91.history.json (5-min curves)
   │     │          consumes events in /tmp/cool91.events/ (pre-warm, hook stats), logs to /var/log/cool91.log
   │     ├─ hook    Claude Code PreToolUse(Bash) entry — reads the snapshot only, 9 ms; posts pre-warm events
   │     └─ status / check / wait / fan / sensors / chip / doctor
   │
   ├─► mcp/cool91_mcp.py   MCP server (Python, stdio): wraps the CLI as 7 tools
   │                      set_fan writes config → guard hot-reloads, same path as the panel, no root
   │
   └─► cool91-panel   menu-bar .app (user level, no root)
                      idle: reads the snapshot for the title only; open: reads history and draws
                      mode / curve edits → write config → guard sees the mtime and reloads
```

**Privilege separation is the heart of the design**: only guard needs root (writes SMC, runs powermetrics). Everything else — panel, hook, statusline — reads 644 JSON files. Non-root parts talk to guard through files: edit the config, or drop a small JSON into `/tmp/cool91.events/` (a 1777 directory) that guard reads and deletes each round.

## Gate logic (Claude Code hook)

Principle: **let the machine go full speed, let the fan prevent throttling, and only make work wait when throttling really happens.** Heat is not the problem; throttling is.

guard reads thermal pressure from `powermetrics` as root; the hook, `cool91 check` and `cool91 wait` share one verdict:

| thermal pressure | hook | `check` exit |
|---|---|---|
| Nominal | allow regardless of temperature; if the command starts with `swift build` / `xcodebuild` / `blender` / `ffmpeg`… post a pre-warm event | 0 |
| Moderate / Heavy, or GPU capped by CLTM > 5% | **wait for recovery (up to 90 s) then allow**, with an explanation | 1 |
| Trapping / Sleeping | **deny**; can be disabled in config | 2 |
| temperature ≥ critical (100 °C) | deny regardless of pressure (safety floor) | 2 |

Without guard (no pressure available) it falls back to temperature: ≥ 95 °C wait, ≥ 100 °C deny.

**Allow-listed commands are never gated**: `cool91`, `kill`, `pkill`, `killall`, `ps`, `top`, `sleep`… — otherwise Claude couldn't even run the commands that cool things down. See `hookAllowCommands` in config.

## Install

Needs Xcode Command Line Tools (`swiftc`). Quit other fan controllers first (e.g. Macs Fan Control, including its menu-bar resident); two writers fight over the fan.

```bash
git clone https://github.com/Okle42/cool91.git
cd cool91
./install.sh     # build → CLI → guard LaunchDaemon (system password dialog) → Claude Code hook + MCP → menu-bar panel
cool91 doctor    # all 15 checks green = done
```

Remove with `./uninstall.sh` (fan handed back to macOS, config kept).

The MCP server needs [`uv`](https://docs.astral.sh/uv/) (fetches `mcp` into an isolated env, never touches system Python); without `uv` or the `claude` CLI, install.sh skips that step and everything else still works.

## Usage

```bash
cool91 status            # temperature / clocks / fan / level / guard / daily stats / pre-warm
cool91 status --short    # 🟡 86°C 🌀3743rpm ⚡3.98GHz (adds "throttled(Moderate)" when it is)
cool91 check ; echo $?   # 0 = go, 1 = throttled, wait, 2 = deny (same verdict as the hook)
cool91 wait              # block until throttling ends; --below 85 waits for the control temp instead
cool91 top               # who's eating CPU (command + cwd), GPU utilisation and clock
cool91 doctor            # checks guard, snapshot, clocks, hook, config, log rotation, conflicting apps
cool91 sensors           # every temperature sensor (for porting to a new chip)
cool91 chip              # chip model and sensor grouping
sudo cool91 fan 3000     # manual RPM; sudo cool91 fan auto hands it back
tail -f /var/log/cool91.log
```

**Panel**: a floating window — click the menu-bar item to show / hide, drag it anywhere, it survives switching apps, follows you across Spaces, remembers its position and sizes itself to its content (drag the height once and it stays; right-click to go back to auto); ✕ top-right collapses it, right-click the menu-bar item for a menu. Dark neon style. First line is the verdict (full speed / throttling / dangerous), then "who's computing" (top two processes with cwd), then temperature / fan / P-core clock cards with 5-minute curves, daily stats, curve preview (current temperature and fan marked), mode picker curve / fixed / auto, quiet / balanced / strong presets or per-point editing. Under the temperature card, "Sensors" expands into the heat grid: P-core / E-core / GPU groups, one cell per SMC sensor (73 on M4), colour by temperature, hover for key and value; collapsed it reads nothing. The "Chimes" card has two independent toggles (overheat / throttled, cooled-down) with ▶ preview and an adjustable trigger temperature each (≥ X° counts as hot, < Y° counts as cool). Two sounds are bundled; override with `"sounds": {"overheat": "~/x.mp3", "cooldown": "~/y.mp3"}` in config. Any change to fan or chimes shows an Apply / Revert bar at the bottom; "Restart" bottom-right relaunches the panel.

**Config** `/etc/cool91/config.json` (see `config.example.json`): curve, thresholds, smoothing, ramp limits, GPU inclusion, allow-list, pre-warm keywords, sensor prefixes, chimes. Hot-reloaded; a parse failure keeps the previous config.

**Log** `/var/log/cool91.log`: timestamped, records only SMC writes, level changes, throttling start / end, config reloads, pre-warms, sensor faults. Rotated by newsyslog at 1 MB.

**Claude Code MCP** (`claude mcp list` should show `cool91: ✔ Connected`). The hook is a passive gate; MCP lets the AI look and act:

| tool | CLI | |
|---|---|---|
| `cool91_status` | `status --json` | temperature / fan / clocks / level / pressure / daily stats / top processes |
| `cool91_check` | `check --json` | adds `verdict: ok / wait / block` — ask before heavy work |
| `cool91_top` | `top` | who's computing |
| `cool91_doctor` | `doctor` | troubleshooting |
| `cool91_wait` | `wait` | wait for throttling to end or `below_temp`, timeout ≤ 300 s |
| `cool91_get_config` | — | read config |
| `cool91_set_fan` | — | `mode=curve / fixed(rpm) / auto`; writes config for guard to hot-reload, rpm clamped to fan min–max |

`cool91_set_fan` deliberately does not call `sudo cool91 fan`: guard rewrites the SMC every 5 s from the curve, so a direct write would be overwritten — and an AI shouldn't hold sudo anyway.

**Claude Code statusline** (optional): `extras/statusline_snippet.py` reads `/tmp/cool91.json` and shows `🌡85°🌀4896⚡3.9G`; hides itself when guard isn't running.

## Is this good for the machine? Will the fan wear out?

**The stock policy first.** Apple's fan strategy is silence-first: the fan reaches 1400 rpm only at 100 °C and the chip lives at 100–107 °C. Nothing in Apple's documentation mentions a target temperature or lifetime; throttling is "expected behaviour". You'll see no visible problem for months — the cost is invisible: after 10–15 minutes of heavy load the M4 mini's P-cores drop from 4464 MHz to 3300–3800 (−15 to −25%), silently.

**cool91's default curve is the A/B-tested "lowest fan that doesn't throttle".** Same load (load 22–42), 5 minutes each (raw data in [`docs/ab-test-2026-09-16/`](docs/ab-test-2026-09-16/)):

| | old curve (aggressive) | **current default** | stock |
|---|---|---|---|
| curve | 55→1000 … 85→4200 90→4900 | 60→1000 75→1800 85→2600 92→3600 97→4900 | — |
| control temp | 83 °C | **87 °C** | 105–107 °C |
| fan | 4216 rpm | **3150 rpm** (−25%, ≈ −6 dB) | ~2100 rpm |
| P-core | 3936 MHz, Nominal | **3936 MHz, Nominal** | 3300–3800 MHz, throttled |

4 °C more buys 25% less fan with zero performance loss and 13 °C of margin to the throttle point. The old curve is still there as the "strong" preset.

**Lifetime**: "every 10 °C halves the life" holds for electromigration-type mechanisms, and Apple's baseline life is long, so 105 → 87 °C is "statistical failure rate ÷ 3", not "breaks vs doesn't". Also often missed: **thermal cycling hurts more than steady heat** — stock swings 45 ↔ 105 °C, cool91 45 ↔ 87, a third less amplitude.

**The fan**: industrial L10 = 70,000 h @ 40 °C, life ∝ (rated ÷ actual rpm)^1.5; even 8 h/day at full speed is 24 years. The real cost is noise and dust. The ceiling is the firmware's own `F0Mx` (4900 on the M4 mini), which Apple uses itself in hot rooms. What actually hurts fans is **frequent start/stop and violent speed changes** — exactly what the asymmetric EMA + ramp limit + deadband prevent: cooling down is capped at −300 rpm per 5 s, so 4900 → 1000 takes at least 65 s. Idle sits at the firmware minimum 1000, same as Apple auto.

**How to know the curve is right**: `cool91 status` daily stats, one number — **seconds throttled should be 0**. If it is, the fan did its job whatever the temperature; if not, raise the hot end of the curve.

**Worst case**: guard dies → launchd `KeepAlive` restarts it in seconds; clean exit always hands the fan back; even with no one in control the SoC has its own hardware protection (throttle, then shutdown). Blow the dust out once a year.

## Measurements (Mac mini M4, macOS 26)

The log the first time it took over (old curve):

```
cool91 guard started (Apple M4, 1 fan, every 5.0s, mode curve, controlling)
🔴 105°C 🌀1774rpm → target 4900 rpm     ← before: macOS auto gave 1774
🟠 100°C 🌀4900rpm
🟠  93°C 🌀4899rpm
🟡  82°C 🌀4618rpm                      ← 20 s later, −23 °C
```

Resources: `guard` 0.1% CPU / 3.5 MB, `powermetrics` child 0.18% / 6 MB; panel idle 0.2% / 33 MB (open 1–3%); `cool91 hook` 9 ms per call; `cool91 status` 0.18 s (including SMC open).

## Problems worth knowing about

The Chinese README has the full list of 18; the ones that matter most if you build on this:

**Apple Silicon SMC is undocumented.** IOKit `AppleSMC`, `IOConnectCallStructMethod` selector 2, an 80-byte `SMCKeyData_t` that must match byte for byte. Written in C; Swift only decodes types (`flt`, `sp78`, `fpe2`, `ui8/16/32`…).

**Nobody knows the sensor key names.** M4 exposes **1375 keys**. Nothing is hard-coded: at start, scan every `T*` key of type `flt`/`sp78` with a value in 10–120, then group by prefix (M4: `Tp*` P-core, `Te*` E-core, `Tg*` GPU, `TH0*` SSD). Prefixes live in config; a new chip is a config change.

**Hardware clocks on M4 are root-only.** IOReport (what macmon / asitop use) reports the *software-requested* DVFS state — under heavy load it sits at the top state (4464) while the hardware actually runs 3936 after power/thermal limiting. Throttling happens exactly there, invisible to IOReport. Only `powermetrics` reads the hardware counters, and it needs root — so guard, already root, keeps one `powermetrics -i 5000` child. (`-n 0` is not infinite; omit `-n`.)

**Other tools show "CPU temperature" 15–20 °C lower.** They read IOHID `PMU tdie` — the Power Management Unit, a separate IC on the board that feeds the SoC. Its trend follows the CPU but it's physically far from the hot spots. M1 still exposed `pACC MTR Temp Sensor` via IOHID; M4 doesn't. cool91 reads the SMC `Tp*` keys next to each P-core, which is also what Apple's own `TCMz` (SoC max) aggregates — measured identical.

**guard starved under load — dead exactly when needed.** The first LaunchDaemon used `ProcessType Background` + `Nice 10`. At load 35 it took three minutes to finish its first round: 1375 SMC calls queued in `mach_msg2_trap` while a normal process scanned the same keys in 0.2 s. Background QoS gets no CPU when the system is busy, and a fan guard is needed precisely then. Now `Standard` + `Nice -5` (actual usage 0.1%), the scanned key list is cached in the snapshot, and a watchdog thread `_exit`s after 6 missed heartbeats so launchd restarts it (a process stuck in a kernel call can't even receive SIGTERM).

**Overwriting the binary in place gets you killed by the kernel.** `cp` onto `/usr/local/bin/cool91` → every new process dies with `OS_REASON_CODESIGNING` (signature cache on the old inode). `cp` to `.new` then `mv`.

**"Who's computing" without powermetrics.** `powermetrics --samplers tasks` costs +2.7% resident and its per-process GPU time is always 0 on Apple Silicon. CPU: `libproc` deltas of per-process CPU time — note `pti_total_user/system` are Mach ticks (125/3 ns) on Apple Silicon, not ns; forget the conversion and you undercount 41×. GPU: IOReport `GPU Performance States` (non-OFF share = utilisation) and `CLTM-induced GPU Performance States` for thermal capping (> 5% non-`NO_CLTM` = GPU throttled).

## Porting to a new chip (M5 / M6…)

1. `cool91 sensors` lists every temperature key and its value
2. `cool91 chip` shows the current grouping
3. Adjust `cpuPrefixes` / `gpuPrefixes` in config
4. If the fan keys are no longer `F0Ac/F0Tg/F0Md`, edit `fan(_:)` / `setFan` in `Sources/Cool91Core/SMC.swift`
5. If `powermetrics` output changes, edit the parser in `Sources/Cool91Core/FreqReader.swift`

## Reports from other chips

Only tested on a **Mac mini M4**. M1 / M2 / M3, Pro / Max / Ultra and MacBooks (battery sensors, possibly different fan keys, no fan on the Air) are untested. Whether it works or not, please open an [issue](https://github.com/Okle42/cool91/issues/new?template=chip-report.yml) with:

```bash
cool91 chip        # chip model, sensor grouping, fan count
cool91 sensors     # every temperature key and its value
cool91 status      # do the readings make sense
cool91 doctor      # which check is not green
```

That's enough to add your chip's prefixes and fan keys to the defaults so the next release works without a config change.

## Layout

```
Sources/CSMC/           80 lines of C: AppleSMC open / read / write / enumerate
Sources/Cool91Core/     SMC decoding, Config, Snapshot / History / Event, FreqReader (powermetrics), Policy (verdict)
Sources/cool91/         CLI: main (dispatch), Hook, Guard, Doctor
Sources/cool91-panel/   menu-bar panel (SwiftUI + Charts)
Tests/Cool91CoreTests/  unit tests: curve interpolation, thresholds, config parse / validate, allow-list, pre-warm, verdict, old snapshots, powermetrics parsing
install/                LaunchDaemon plist, newsyslog config, Claude Code hook snippet
scripts/                install-root.sh (root steps), install-hook.py, install-mcp.sh, make-app.sh (panel bundle)
mcp/                    cool91_mcp.py: MCP server (PEP 723 single file, uv run --script)
Sounds/                 bundled chimes overheat.m4a / cooldown.m4a (synthesised, packed into the panel app)
extras/                 statusline snippet, perf_vs_temp.py (efficiency vs temperature), make_sounds.py (chime synthesis)
docs/                   A/B test data
```

`swift test` runs the unit tests; `./install.sh` installs everything.

## Docs

- [`docs/findings-m4-sensors.md`](docs/findings-m4-sensors.md) — **technical findings (zh / en)**: IOReport clocks vs IOHID temperatures vs SMC vs powermetrics on M4, second-by-second comparison, which ones are real; stock fan policy numbers; what an agent should use to self-throttle
- [`docs/ab-test-2026-09-16/`](docs/ab-test-2026-09-16/) — raw A/B curve data, powermetrics output, external references
- [`CHANGELOG.md`](CHANGELOG.md)

## License

MIT
