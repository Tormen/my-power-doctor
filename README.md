# my-power-doctor

Diagnose **and act on** what's keeping macOS from sleeping.

POSIX `sh`/`dash` compatible. Targets macOS (BSD userland). Designed for
Klaus' `my-*` toolchain conventions (config search path, `--config`,
`--create-config`, `-D|--debug`, whitelist support, state-file restore).

---

## What it does

| Action             | Source                              | Purpose                                          |
| ------------------ | ----------------------------------- | ------------------------------------------------ |
| *(no action)*      | parsed assertions + state + log     | **Default**: synthesised one-screen summary. Add `-D` to see the full raw blocks (culprits table + state + 10-event timeline + raw wake-reason lines) BEFORE the summary. |
| `status`           | + `pmset -g`, `-g sched`            | Verbose superset: host info + pmset settings + scheduled wakes + raw blocks + summary (regardless of `-D`). |
| `assertions`       | `pmset -g assertions`               | Raw dump                                         |
| `culprits`         | parsed `pmset -g assertions`        | Compact table: PID / proc / assertion / label    |
| `wake-history`     | `pmset -g log`, `log show`          | **Narrative timeline** of the last N (default 10) power events |
| `wake-history-raw` | `pmset -g log`                      | Underlying raw pmset log lines (escape hatch)    |
| `scheduled`        | `pmset -g sched` + launchd plists   | Scheduled wakes (Time Machine, calendar, …)      |
| `kill <SEL>`       | `kill(1)`                           | **One-shot** — launchd may restart               |
| `prevent <SEL>`    | `launchctl disable` + `bootout`     | **Persistent** — survives reboot                 |
| `restore <SEL>`    | `launchctl enable` + `kickstart`    | Undo `prevent`                                   |
| `state`            | state file                          | What we've disabled (and when)                   |

### Default output — synthesised summary

Bare `my-power-doctor` prints a single ~20-line synthesis answering "is
anything weird?":

```
== summary ==
  Right now:
    - 1 active sleep blocker(s), all benign
        powerd (pid 127) PreventUserIdleSystemSleep, held 00:09:25 (benign -- "display is on")
    - 0 services prevented

  Recent activity (last 10 events, 2026-05-24 21:03 -> 2026-05-24 21:09):
    21:03  prevent      Signal started blocking system sleep ("Preparing to relaunch")
    21:03  prev. end    Signal ended blocking system sleep ("Preparing to relaunch", held 00:00:00)
    21:03  prevent      ShipIt started blocking system sleep ("Updating") (x2)
    ...

  Wake reasons (unified log, last 24h):
    - 7 distinct Wake-on-WiFi darkwake(s): 19:25 19:40 20:06 20:22 20:24 20:48 21:03
      (airportd "Wake Reason not found" -- housekeeping; no user wake)
    - 0 other wake-reason line(s)
```

The summary classifies active blockers into **real** vs **benign**:

- **Benign**: powerd's `"Powerd - Prevent sleep while display is on"`
  assertion (which just means the display is on; not a runaway), and
  any blocker that matches the configured whitelist.
- **Real**: anything else — i.e. an app the user might actually want
  to inspect or stop.

Wake-reason lines are grouped: `systemWokenByWiFi` lines (often
duplicated by airportd) are deduped to distinct minute-precision wake
times, and counted separately from "other" wake-reason lines.

**`-D` shows the full raw blocks BEFORE the summary** — that's the
old-style culprits table, the state-file listing, the 10-event narrative
timeline, and the raw unified-log wake-reason lines.

### `wake-history` — narrative timeline

`wake-history` (and the tail of every default/`status` invocation) parses
`pmset -g log` into a categorised stream of *real* power events, then
shows the last N (default 10):

```
== last 10 power events (oldest first; "*" marks a power-state change) ==
  *  2026-05-24 19:20:35    DISPLAY-OFF  Display turned OFF
     2026-05-24 19:22:46    PREVENT-END  backupd-helper ended preventing idle sleep ("Mutexed Backup Block", held 00:00:30)
     2026-05-24 19:26:00..19:40:57  NOTIF-WAKE   Display lit by NotificationCenter (x5)
     2026-05-24 19:41:15    PREVENT-END  coreaudiod ended preventing idle sleep ("audio playback", held 00:00:34) (x7)
  *  2026-05-24 20:06:39    DISPLAY-ON   Display turned ON
  *  2026-05-24 20:22:00    DISPLAY-OFF  Display turned OFF
  *  2026-05-24 20:24:12    DISPLAY-ON   Display turned ON
```

Categories: `DISPLAY-ON` / `DISPLAY-OFF` / `SLEEP` / `WAKE` / `HIBERNATE`
/ `DARK-WAKE` (MaintenanceWake) / `DARK-PROBE` (powerd inactivity probe)
/ `PREVENT` / `PREVENT-END` (sleep blockers started/ended) / `CAFFEINATE`
(NoIdleSleep / NoDisplaySleep holds) / `NOTIF-WAKE` (NotificationCenter
lighting the screen for a banner) / `BATTERY` (BatteryHealth notices).

`*` flags "real" power-state transitions (display on/off, sleep, wake,
hibernate, dark wake). Adjacent identical events are collapsed with
`(xN)` and a time range. `coreaudiod`'s per-audio-channel assertions are
normalised to `"audio playback"` so they collapse cleanly.

`BackgroundTask`, `ApplePushServiceTask`, `NetworkClientActive`,
`UserIsActive` and `Summary` lines are filtered as noise. The chatty
`powerd` / `"Prevent sleep while display is on"` pair is dropped because
it already maps 1:1 to the `DISPLAY-ON` / `DISPLAY-OFF` notifications.

Override the count via `WAKE_HISTORY_EVENTS` in the config file. Use
`wake-history-raw` if the narrative view is hiding something you want
to see.

### Selectors

For `kill` / `prevent` / `restore`:

- `all` — every non-whitelisted blocker (respects whitelist)
- `#N` or `N` — row number from the most recent list:
    - For `kill` / `prevent`: refers to the last `culprits` output
      (cached at `$STATE_DIR/last-culprits.tsv`).
    - For `restore`: refers to the current `state` output (line N of the
      state file).
- `<pid>` — numeric PID (use `#N` if you want a row number explicitly)
- `<name>` — substring of process name (e.g. `coreaudiod`, `rapportd`)
- `<label>` — launchd label or substring (e.g. `com.apple.rapportd`)

**The whitelist always applies — including to targeted selectors.** This
protects you from typos like `prevent #1` accidentally nuking
`WindowServer`. To act on a whitelisted row, you must pass `--force`:

```sh
sudo my-power-doctor prevent #2                 # skipped if #2 is whitelisted
sudo my-power-doctor --force prevent #2         # acts on it (loud override message)
```

The override is logged loudly in the output (`[force: whitelist
overridden] …`) so a `--force` in your shell history is never invisible.

---

## Quick start

```sh
# install
sudo install -m 0755 my-power-doctor /usr/local/bin/

# first look — no changes
my-power-doctor                       # default: synthesised one-screen summary
my-power-doctor -D                    # raw blocks + summary (verbose default)
my-power-doctor status                # verbose superset (+ pmset settings, scheduled wakes, raw, summary)
my-power-doctor culprits              # just the culprit table
my-power-doctor wake-history          # narrative timeline of last 10 power events
my-power-doctor wake-history-raw      # raw pmset log lines (escape hatch)
sudo my-power-doctor                  # +real wake-reason summary (root only)

# write the default config to your /LINKS/default
my-power-doctor --create-config /LINKS/default/my-power-doctor.conf

# now act
sudo my-power-doctor kill rapportd            # one-shot, will restart
sudo my-power-doctor prevent com.apple.rapportd   # persistent
sudo my-power-doctor state                    # see what's disabled
sudo my-power-doctor restore com.apple.rapportd   # bring it back
sudo my-power-doctor restore all              # bring all back

# nuke everything non-whitelisted, persistently (read the prompt!)
sudo my-power-doctor prevent all
```

---

## Config

### Search order (first existing file wins)

```
/LINKS/default/my-power-doctor.conf
~/.my-power-doctor.conf
/etc/my-power-doctor.conf
/usr/local/etc/my-power-doctor.conf
```

### Flags

- `--config PATH` — override; prints which file is used.
- `--create-config [PATH]` — write default config to PATH or stdout.
  Never overwrites an existing file.
- `-D | --debug` — verbose mode: show the full raw blocks (culprits, state,
  10-event timeline, raw wake-reason lines) BEFORE the synthesised summary.
  Also appends a debug trace to `$DEBUG_LOG`.
- `-n | --dry-run` — print intended actions only.
- `-f | --force` — act on whitelisted rows too. Required to touch any
  row marked `W` in the culprits table. The override is loudly logged.
- `-y | --yes` — skip confirmation prompts.

### Config file (sourced as POSIX sh)

```sh
# State directory (where prevented services are recorded for restore)
# STATE_DIR="/var/db/my-power-doctor"             # when run as root
# STATE_DIR="${HOME}/.my-power-doctor"            # when run as user

# Debug log location
# DEBUG_LOG="/var/log/my-power-doctor.log"        # when run as root
# DEBUG_LOG="${HOME}/.my-power-doctor.log"        # when run as user

# Assertion types treated as "blocks sleep"
# SLEEP_ASSERTIONS="PreventUserIdleSystemSleep PreventSystemSleep NoIdleSleepAssertion"
# DISPLAY_ASSERTIONS="PreventUserIdleDisplaySleep NoDisplaySleepAssertion"

# Whitelist — space-separated tokens.  A token matches against:
#   - exact PID
#   - substring of process name
#   - substring of launchd label
#   - exact assertion type
# Whitelisted entries are NEVER killed/prevented (even with selector "all").
WHITELIST="WindowServer loginwindow coreaudiod hidd \
           com.apple.WindowServer com.apple.loginwindow \
           NoDisplaySleepAssertion"

# How many raw lines 'wake-history-raw' shows
# WAKE_HISTORY_LINES=40

# How many extracted power events 'wake-history' (and the default view) shows
# WAKE_HISTORY_EVENTS=10
```

The whitelist gets a `W` flag in the `culprits` view so you can see at a
glance what `all` will skip.

---

## Permissions matrix

| Action                | Run as                                          |
| --------------------- | ----------------------------------------------- |
| `status` / `culprits` | `[as me]` — partial label resolution            |
| `wake-history`        | `[as me]` works; `[as root]` for full `log show`|
| `scheduled`           | `[as me]`                                       |
| `kill <user-proc>`    | `[as me]` for your own PIDs                     |
| `kill <system-proc>`  | `[as root]`                                     |
| `prevent` / `restore` | `[as root]` (touches `system/` launchd domain)  |

Run user-context probes as `me`; touching `system/<label>` requires `root`.
The script refuses `prevent`/`restore` if not root.

---

## How "prevent" actually works

For a blocker whose launchd label is `com.apple.rapportd` in domain `system`:

```sh
launchctl disable system/com.apple.rapportd   # persistent override
launchctl bootout  system/com.apple.rapportd   # stop running instance now
```

`disable` survives reboot — the service won't come back until:

```sh
launchctl enable    system/com.apple.rapportd
launchctl kickstart system/com.apple.rapportd   # start now (otherwise on demand)
```

…which is what `restore` does. The state file at
`$STATE_DIR/disabled.tsv` records every `(label, domain)` pair we
disabled, so `restore all` works even after a reboot.

If a blocker has **no launchd label** (e.g. an interactive `caffeinate`
launched from a terminal), `prevent` cannot work on it — use `kill` instead.
The script will warn and skip cleanly.

---

## Typical workflow when "my Mac stopped sleeping"

```sh
# 1.  What's holding it open?
sudo my-power-doctor culprits

#    Example output:
#       #   W  PID    PROCESS                ASSERTION                        HELD       LABEL [domain]
#       --- -  -----  ----------------------  ------------------------------  ---------- -------------------
#      #1  W  287    WindowServer           PreventUserIdleDisplaySleep      02:11:09   com.apple.WindowServer [system]
#      #2     396    rapportd               PreventUserIdleSystemSleep       03:19:31   com.apple.rapportd [system]
#      #3     1023   zoom.us                PreventUserIdleSystemSleep       00:14:55   us.zoom.xos [gui/501]
#      #4     5577   caffeinate             PreventSystemSleep               01:02:33   ? [system]

# 2.  Why did it wake last time?
sudo my-power-doctor wake-history

# 3.  Any scheduled wakes (TM, calendar)?
my-power-doctor scheduled

# 4.  Decide: one-shot or persistent? Use #N from the table above.
sudo my-power-doctor kill #4              # stops the caffeinate (one-shot)
sudo my-power-doctor prevent #2           # persistently disable rapportd
#  or by name/label:
sudo my-power-doctor prevent com.apple.rapportd

# 5.  Later, list what we disabled and undo
sudo my-power-doctor state
sudo my-power-doctor restore #1           # undo first state entry
sudo my-power-doctor restore all
```

---

## Safety / dry-run

Every destructive action accepts `-n` / `--dry-run`:

```sh
sudo my-power-doctor -n prevent all       # show what would happen, do nothing
```

`prevent all` and `kill all` prompt for confirmation unless `-y` is given.

---

## Exit codes

| Code | Meaning                                          |
| ---- | ------------------------------------------------ |
| 0    | OK                                               |
| 1    | Generic error (missing root, bad config, ...)    |
| 2    | Usage error (unknown flag / action)              |
| 3    | Nothing matched / nothing to do                  |

---

## Files

```
/usr/local/bin/my-power-doctor
/LINKS/default/my-power-doctor.conf       (recommended canonical config)
/var/log/my-power-doctor.log              (debug, when run as root)
/var/db/my-power-doctor/disabled.tsv      (state, when run as root)
/var/db/my-power-doctor/last-culprits.tsv (cache of last culprits list)
~/.my-power-doctor.log                    (debug, when run as user)
~/.my-power-doctor/disabled.tsv           (state, when run as user)
~/.my-power-doctor/last-culprits.tsv      (cache of last culprits list)
```

State file format (TSV):

```
WHEN  LABEL  DOMAIN  PID_AT_TIME  PROC_NAME  ASSERTION_TYPE
```

---

## Limitations / known caveats

- `PreventUserIdleDisplaySleep` only blocks **display** sleep. By default
  it's *included* in `culprits` so you can see it, but you may want to
  whitelist `PreventUserIdleDisplaySleep` and `NoDisplaySleepAssertion`
  if you only care about full system sleep.
- `WindowServer` holds a display-sleep assertion as long as you're logged
  in. **Do not kill it.** It's in the default whitelist for a reason.
- `launchctl disable` is sticky. If you `prevent` something and forget,
  it stays disabled even after software updates until you `restore` (or
  manually `launchctl enable`).
- Bluetooth/USB HID kernel assertions are surfaced by `assertions` but
  not actionable from userland — they reflect actual hardware activity.
