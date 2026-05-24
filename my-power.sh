#!/bin/sh
# my-power-doctor — diagnose & manage what's keeping macOS awake
#
# POSIX sh / dash compatible. Targets macOS (BSD userland).
#
# Primary signals used:
#   pmset -g assertions     — who holds PreventUserIdleSystemSleep etc.
#   pmset -g log            — sleep/wake history & wake reasons
#   pmset -g sched          — scheduled wakes (Time Machine, calendar, ...)
#   launchctl list / print  — map PID → launchd label (for persistent prevent)
#
# Actions:
#   status              show summary + active sleep blockers (default)
#   assertions          full pmset assertion dump (parsed)
#   wake-history        recent sleep/wake events from pmset log
#   scheduled           scheduled wakes
#   culprits            just the list of processes blocking sleep
#   kill <SEL>          SIGTERM blocker(s)        — one-shot (launchd may restart)
#   prevent <SEL>       launchctl disable+bootout — persistent (won't restart)
#   restore <SEL>|all   undo prevent (launchctl enable + kickstart)
#   state               show what we have disabled (state file)
#
# Selectors (for kill / prevent / restore):
#   all                 every non-whitelisted blocker
#   <pid>               numeric PID
#   <name>              process name substring (e.g. coreaudiod)
#   <label>             launchd label (e.g. com.apple.rapportd)
#
# Klaus conventions:
#   - Config search:  /LINKS/default → ~/ → /etc → /usr/local/etc (first hit)
#   - --config PATH      override resolved config (and print it)
#   - --create-config [PATH]   write default to PATH or stdout (never auto-writes)
#   - -D | --debug       log to debug file (configurable)
#   - Ships with README.md

set -u

PROG="my-power-doctor"
VERSION="1.1.0"

# ----------------------------------------------------------------------------
# DEFAULTS (overridable by config file)
# ----------------------------------------------------------------------------

# State directory: where we record what we've disabled so we can restore.
# Root invocations use /var/db; user invocations use ~/.
if [ "$(id -u)" -eq 0 ]; then
    DEFAULT_STATE_DIR="/var/db/my-power-doctor"
else
    DEFAULT_STATE_DIR="${HOME}/.my-power-doctor"
fi
STATE_DIR="$DEFAULT_STATE_DIR"

# Debug log
if [ "$(id -u)" -eq 0 ]; then
    DEFAULT_DEBUG_LOG="/var/log/my-power-doctor.log"
else
    DEFAULT_DEBUG_LOG="${HOME}/.my-power-doctor.log"
fi
DEBUG_LOG="$DEFAULT_DEBUG_LOG"

# Which assertion types we treat as "blocks sleep". Space-separated.
# Display-sleep blockers are listed too but flagged differently.
SLEEP_ASSERTIONS="PreventUserIdleSystemSleep PreventSystemSleep NoIdleSleepAssertion"
DISPLAY_ASSERTIONS="PreventUserIdleDisplaySleep NoDisplaySleepAssertion"

# Whitelist (space-separated tokens). A token matches if it appears as:
#   - exact PID
#   - substring of process name
#   - substring of launchd label
#   - exact assertion type
WHITELIST=""

# How many lines of wake-history to show
WAKE_HISTORY_LINES=40

# How many extracted power events to show in 'wake-history' (narrative view).
# Events are: display on/off, dark/maintenance wakes, sleep blockers started/ended,
# battery health, hibernate/sleep transitions. Counts back across the full
# pmset log regardless of age.
WAKE_HISTORY_EVENTS=10

# Config file resolution (first existing wins)
CONFIG_SEARCH="/LINKS/default/my-power-doctor.conf ${HOME}/.my-power-doctor.conf /etc/my-power-doctor.conf /usr/local/etc/my-power-doctor.conf"

# ----------------------------------------------------------------------------
# Runtime state
# ----------------------------------------------------------------------------
DEBUG=0
DRY_RUN=0
FORCE=0                  # --force: act on whitelisted rows
CONFIG_FILE=""           # resolved
CONFIG_FILE_ARG=""       # if user gave --config
ACTION=""
SELECTOR=""

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
die() {
    printf '%s: error: %s\n' "$PROG" "$*" >&2
    exit 1
}

warn() {
    printf '%s: warning: %s\n' "$PROG" "$*" >&2
}

log_debug() {
    [ "$DEBUG" -eq 1 ] || return 0
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s [%s] %s\n' "$_ts" "$$" "$*" >> "$DEBUG_LOG" 2>/dev/null || true
}

need_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "this script targets macOS (Darwin) only"
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "$1 requires root (re-run as root)"
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

confirm() {
    # confirm "Prompt text"  → returns 0 on yes, 1 on no
    _prompt="$1"
    printf '%s [y/N] ' "$_prompt" >&2
    read -r _ans || return 1
    case "$_ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<EOF
$PROG $VERSION — diagnose & manage macOS sleep blockers

USAGE:
    $PROG [GLOBAL OPTS] <action> [args...]

ACTIONS:
    (no action)             Default lean view: active sleep blockers +
                            prevented services + the last N power events
                            (default N=10, see WAKE_HISTORY_EVENTS).
    status                  Verbose superset of the default: also includes
                            host info, 'pmset -g' sleep settings, and
                            scheduled wakes ('pmset -g sched').
    assertions              Full parsed dump of pmset -g assertions.
    culprits                Compact list of PID/name/label/assertion.
    wake-history            Narrative timeline of the last N (default 10)
                            real power events extracted from pmset -g log
                            (display on/off, dark/maintenance wakes, sleep
                            blockers started/ended, hibernate, battery health).
                            N is set by WAKE_HISTORY_EVENTS in the config.
    wake-history-raw        Underlying raw pmset -g log lines (sleep|wake|
                            assertion|battery), tail-N. Use when the narrative
                            view is hiding something you want to see.
    scheduled               Scheduled wakes (pmset -g sched).
    kill <selector>         SIGTERM blocker(s). One-shot — launchd may restart.
    prevent <selector>      Persistently disable via launchctl.
                            Survives restart until 'restore'.
    restore <selector|all>  Re-enable previously prevented services.
    state                   Show what we've disabled & when.

SELECTORS:
    all                     Every non-whitelisted blocker.
    #N | N                  Row number from the most recent culprits/state list.
                            For kill/prevent: refers to last 'culprits' output.
                            For restore:      refers to current 'state' output.
    <pid>                   Numeric PID (use #N for unambiguous "row number").
    <name>                  Process name substring (e.g. coreaudiod, rapportd).
    <label>                 Launchd label or substring (e.g. com.apple.rapportd).

    Note: The whitelist ALWAYS applies — including to targeted selectors
    (#N, name, label, pid). Use --force to override it for whitelisted
    rows you really do want to act on (e.g. a row you've added to the
    whitelist but want to act on just this once).

GLOBAL OPTS:
    --config <PATH>         Use this config file (and print which one).
    --create-config [PATH]  Write default config to PATH or stdout. Never
                            auto-writes existing files.
    -D | --debug            Append debug trace to \$DEBUG_LOG.
    -n | --dry-run          Print intended actions, do nothing.
    -f | --force            Act on whitelisted rows too (the whitelist normally
                            protects ALL selectors, including #N and by-name).
    -y | --yes              Don't prompt for confirmation on destructive ops.
    -h | --help             This help.
    -V | --version          Print version.

CONFIG SEARCH ORDER (first hit wins):
    /LINKS/default/$PROG.conf
    ~/.$PROG.conf
    /etc/$PROG.conf
    /usr/local/etc/$PROG.conf

EXAMPLES:
    $PROG                                  # default: culprits + state
    $PROG status                           # verbose overview
    sudo $PROG culprits
    sudo $PROG kill rapportd               # by name
    sudo $PROG kill 2                      # by row number from last culprits
    sudo $PROG prevent #2                  # # is optional
    sudo $PROG prevent com.apple.rapportd  # by label
    sudo $PROG restore 1                   # row 1 of 'state' list
    sudo $PROG restore all
    $PROG --create-config /LINKS/default/$PROG.conf

EXIT STATUS:
    0  ok                 1  generic error
    2  usage error        3  no blockers found / nothing to do
EOF
}

# ----------------------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------------------
print_default_config() {
    cat <<'EOF'
# my-power-doctor.conf — sourced as POSIX sh
#
# All values are optional; commented entries show defaults.

# State directory (where we record disabled services for restore)
# STATE_DIR="/var/db/my-power-doctor"             # when run as root
# STATE_DIR="${HOME}/.my-power-doctor"            # when run as user

# Debug log location
# DEBUG_LOG="/var/log/my-power-doctor.log"        # when run as root
# DEBUG_LOG="${HOME}/.my-power-doctor.log"        # when run as user

# Assertion types that "block sleep" (system / display)
# SLEEP_ASSERTIONS="PreventUserIdleSystemSleep PreventSystemSleep NoIdleSleepAssertion"
# DISPLAY_ASSERTIONS="PreventUserIdleDisplaySleep NoDisplaySleepAssertion"

# Whitelist — space-separated tokens. Each token is matched against:
#   - exact PID
#   - substring of process name
#   - substring of launchd label
#   - exact assertion type
# Whitelisted entries are *never* killed/prevented (even with 'all').
#
# Reasonable starting point — these are almost always benign or essential:
WHITELIST="WindowServer loginwindow coreaudiod hidd \
           com.apple.WindowServer com.apple.loginwindow \
           NoDisplaySleepAssertion"

# How many lines of wake-history to show by default
# WAKE_HISTORY_LINES=40

# How many extracted power events to show in 'wake-history' (narrative view).
# WAKE_HISTORY_EVENTS=10
EOF
}

resolve_config() {
    # If user passed --config <PATH>, use that (must exist).
    if [ -n "$CONFIG_FILE_ARG" ]; then
        [ -f "$CONFIG_FILE_ARG" ] || die "--config: file not found: $CONFIG_FILE_ARG"
        CONFIG_FILE="$CONFIG_FILE_ARG"
        return 0
    fi
    # Otherwise walk the search path.
    for _f in $CONFIG_SEARCH; do
        if [ -f "$_f" ]; then
            CONFIG_FILE="$_f"
            return 0
        fi
    done
    CONFIG_FILE=""
}

load_config() {
    if [ -n "$CONFIG_FILE" ]; then
        log_debug "loading config: $CONFIG_FILE"
        # shellcheck disable=SC1090
        . "$CONFIG_FILE" || warn "failed to source $CONFIG_FILE"
    fi
}

# ----------------------------------------------------------------------------
# WHITELIST matching
# ----------------------------------------------------------------------------
# Returns 0 if any of (pid, name, label, type) matches a whitelist token.
is_whitelisted() {
    _pid="$1"; _name="$2"; _label="$3"; _type="$4"
    [ -n "$WHITELIST" ] || return 1
    for _tok in $WHITELIST; do
        [ "$_tok" = "$_pid"  ] && return 0
        [ "$_tok" = "$_type" ] && return 0
        case "$_name"  in *"$_tok"*) return 0 ;; esac
        case "$_label" in *"$_tok"*) return 0 ;; esac
    done
    return 1
}

# ----------------------------------------------------------------------------
# pmset assertion parsing
# ----------------------------------------------------------------------------
# Emits, one per line, TAB-separated:
#   PID<TAB>PROCNAME<TAB>ASSERTION_TYPE<TAB>HELD_FOR<TAB>NAME
#
# Example pmset -g assertions excerpt:
#   pid 396(rapportd): [0x00...] 03:19:31 PreventUserIdleSystemSleep named: "..."
#       Created for PID: 396.
# Some lines have no `named:` part — we set NAME to "-".
parse_assertions() {
    pmset -g assertions 2>/dev/null | awk '
        BEGIN { in_listed = 0 }
        /^Listed by owning process:/ { in_listed = 1; next }
        /^Kernel Assertions/         { in_listed = 0 }
        /^Idle sleep preventers/     { in_listed = 0 }
        in_listed && /^[[:space:]]*pid[[:space:]]+[0-9]+\(/ {
            line = $0
            # extract PID
            sub(/^[[:space:]]*pid[[:space:]]+/, "", line)
            pid = line + 0
            # extract proc name between ( and )
            n = index(line, "(")
            rest = substr(line, n + 1)
            cl  = index(rest, ")")
            procname = substr(rest, 1, cl - 1)
            after = substr(rest, cl + 1)
            # after looks like: ": [0x...] 03:19:31 PreventUserIdleSystemSleep named: \"...\" ..."
            # strip leading ": ["
            sub(/^[: \t]*\[[^]]*\][[:space:]]*/, "", after)
            # next token: held-for duration
            split(after, parts, /[[:space:]]+/)
            held = parts[1]
            atype = parts[2]
            # named: "..." — extract content between first pair of double quotes
            name = "-"
            qi = index(after, "named:")
            if (qi > 0) {
                tail = substr(after, qi)
                q1 = index(tail, "\"")
                if (q1 > 0) {
                    tail2 = substr(tail, q1 + 1)
                    q2 = index(tail2, "\"")
                    if (q2 > 0) name = substr(tail2, 1, q2 - 1)
                }
            }
            printf "%s\t%s\t%s\t%s\t%s\n", pid, procname, atype, held, name
        }
    '
}

# Filter parse_assertions output to sleep blockers only (system+display by default).
filter_sleep_blockers() {
    # arg 1: "all" | "system" | "display"   (default "all")
    _mode="${1:-all}"
    case "$_mode" in
        system)  _types="$SLEEP_ASSERTIONS" ;;
        display) _types="$DISPLAY_ASSERTIONS" ;;
        *)       _types="$SLEEP_ASSERTIONS $DISPLAY_ASSERTIONS" ;;
    esac
    awk -v types="$_types" '
        BEGIN { n = split(types, T, " "); for (i=1;i<=n;i++) wanted[T[i]] = 1 }
        { if ($3 in wanted) print }
    '
}

# ----------------------------------------------------------------------------
# PID → launchd label mapping
# ----------------------------------------------------------------------------
# Echoes:  LABEL<TAB>DOMAIN   (DOMAIN like "system" or "gui/501")
# Echoes empty on failure.
pid_to_launchd() {
    _pid="$1"
    [ -n "$_pid" ] || { printf '\t'; return 1; }

    # Try `launchctl procinfo` (requires root for most system services).
    # Output contains lines like "service name = com.apple.foo"
    # and "domain = system" or "domain = gui/501 ..."
    _info=$(launchctl procinfo "$_pid" 2>/dev/null || true)
    if [ -n "$_info" ]; then
        _label=$(printf '%s\n' "$_info" \
            | awk -F'=' '/^[[:space:]]*service name[[:space:]]*=/{
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit
            }')
        _domain=$(printf '%s\n' "$_info" \
            | awk -F'=' '/^[[:space:]]*domain[[:space:]]*=/{
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                # take first word only ("system" or "gui/501" etc.)
                split($2, a, /[[:space:]]+/); print a[1]; exit
            }')
        if [ -n "$_label" ]; then
            printf '%s\t%s\n' "$_label" "${_domain:-system}"
            return 0
        fi
    fi

    # Fallback: `launchctl list | awk '$1==pid {print $3}'` (user domain only)
    _label=$(launchctl list 2>/dev/null \
        | awk -v p="$_pid" 'NR>1 && $1==p { print $3; exit }')
    if [ -n "$_label" ]; then
        # user domain — guess gui/<uid>
        _uid=$(id -u)
        printf '%s\tgui/%s\n' "$_label" "$_uid"
        return 0
    fi

    printf '\t'
    return 1
}

# ----------------------------------------------------------------------------
# DISPLAY: default / status / culprits / wake-history / scheduled
# ----------------------------------------------------------------------------
# Default action when no verb is given: the lean view —
#   "is anything blocking sleep right now?", "what have I disabled?",
#   "what just happened power-wise?".  No pmset settings / scheduled wakes
#   header (use 'status' for that).
action_default() {
    action_culprits
    printf '\n'
    action_state
    printf '\n'
    action_wake_history
}

action_status() {
    printf '== %s status ==\n' "$PROG"
    printf '  host:      %s\n' "$(hostname -s)"
    printf '  uname:     %s\n' "$(uname -srm)"
    printf '  config:    %s\n' "${CONFIG_FILE:-<none>}"
    printf '  state dir: %s\n' "$STATE_DIR"
    printf '  whitelist: %s\n' "${WHITELIST:-<empty>}"
    printf '\n'

    printf '== sleep settings (pmset -g) ==\n'
    pmset -g 2>/dev/null | sed 's/^/  /'
    printf '\n'

    printf '== scheduled wakes (pmset -g sched) ==\n'
    pmset -g sched 2>/dev/null | sed 's/^/  /'
    printf '\n'

    action_culprits
    printf '\n'

    action_state
    printf '\n'

    action_wake_history
    printf '\n'

    printf 'Tip:  %s wake-history    %s prevent <name>    %s restore all\n' \
        "$PROG" "$PROG" "$PROG"
}


# Compact culprit list, one per line, with launchd label resolution.
# Side-effect: writes $STATE_DIR/last-culprits.tsv so 'prevent N' works.
action_culprits() {
    printf '== sleep blockers (active assertions) ==\n'
    _rows=$(parse_assertions | filter_sleep_blockers all)
    if [ -z "$_rows" ]; then
        printf '  (none — nothing is currently blocking sleep)\n'
        # Truncate stale cache so 'prevent N' can't resurrect old entries.
        _cf=$(last_culprits_file)
        if [ -f "$_cf" ]; then
            : > "$_cf" 2>/dev/null || true
        fi
        return 0
    fi
    printf '  %-3s %1s %-5s %-22s %-32s %-10s %s\n' \
        '#'   ''  'PID'   'PROCESS' 'ASSERTION' 'HELD' 'LABEL [domain]'
    printf '  %-3s %1s %-5s %-22s %-32s %-10s %s\n' \
        '---' '-' '-----' '----------------------' \
        '--------------------------------' '----------' \
        '----------------------------------------'

    # Prepare cache file (best-effort: don't die if we can't create state dir
    # for non-destructive ops).
    _cf=$(last_culprits_file)
    if mkdir -p "$STATE_DIR" 2>/dev/null; then
        : > "$_cf" 2>/dev/null || _cf=""
    else
        _cf=""
    fi

    # Use a temp file so the while-loop counter is preserved (no pipe-subshell).
    _tmp=$(mktemp 2>/dev/null || printf '/tmp/mpd.c.%s' $$)
    printf '%s\n' "$_rows" > "$_tmp"
    _n=0
    while IFS='	' read -r pid name atype held aname; do
        _n=$((_n + 1))
        _ll=$(pid_to_launchd "$pid")
        _label=$(printf '%s' "$_ll" | cut -f1)
        _dom=$(  printf '%s' "$_ll" | cut -f2)
        _flag=' '
        if is_whitelisted "$pid" "$name" "$_label" "$atype"; then
            _flag='W'
        fi
        _disp_label="${_label:-?}"
        [ -n "$_dom" ] && _disp_label="$_disp_label [$_dom]"
        printf '  #%-2d %1s %-5s %-22s %-32s %-10s %s\n' \
            "$_n" "$_flag" "$pid" "$name" "$atype" "$held" "$_disp_label"
        if [ -n "$_cf" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_n" "$pid" "$name" "${_label:-}" "${_dom:-}" \
                "$atype" "$held" "$aname" >> "$_cf"
        fi
    done < "$_tmp"
    rm -f "$_tmp"
    printf '\n  (W = whitelisted: protected from kill/prevent;\n'
    printf '   use --force to act on whitelisted rows)\n'
}

action_assertions() {
    printf '== pmset -g assertions (raw) ==\n'
    pmset -g assertions 2>/dev/null
}

# Extract a narrative timeline of "real" power events from pmset -g log
# (display on/off, sleep blockers started/ended, dark/maintenance wakes,
# hibernate transitions, battery-health notices). One row per event,
# TAB-separated:  TIMESTAMP \t CATEGORY \t DESCRIPTION
# Writes to stdout; designed to be tail-clipped by the caller.
extract_power_events() {
    _src="$1"   # path to captured pmset -g log
    awk '
        # ----- helpers -----
        function ts(s)         { return substr(s, 1, 19) }
        function strip_q(s)    { gsub(/^"|"$/, "", s); return s }
        function action_verb(a) {
            if (a == "Created")  return "started"
            if (a == "Released") return "ended"
            if (a == "TimedOut") return "timed out"
            return a
        }

        # ----- Notification: display backlight toggles -----
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}.*Notification.*Display is turned on/ {
            printf "%s\tDISPLAY-ON\tDisplay turned ON\n", ts($0); next
        }
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}.*Notification.*Display is turned off/ {
            printf "%s\tDISPLAY-OFF\tDisplay turned OFF\n", ts($0); next
        }

        # ----- Notification: explicit Sleep / Wake / Hibernate lines     -----
        # ----- (present on some macOS releases, absent on others)        -----
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}.*Notification.*(Entering Sleep|Going to sleep)/ {
            printf "%s\tSLEEP\tSystem entering sleep\n", ts($0); next
        }
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}.*Notification.*(Wake from|Waking from sleep)/ {
            line = $0
            sub(/.*Notification[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            printf "%s\tWAKE\t%s\n", ts($0), line; next
        }
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}.*(Hibernate|hibernat)/ {
            line = $0
            sub(/.*(Notification|Assertions|Sleep)[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            printf "%s\tHIBERNATE\t%s\n", ts($0), line; next
        }

        # ----- BatteryHealth -----
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}.*BatteryHealth/ {
            _ts = ts($0); msg = $0
            sub(/.*BatteryHealth[[:space:]]+/, "", msg)
            sub(/[[:space:]]+$/, "", msg)
            printf "%s\tBATTERY\tBattery: %s\n", _ts, msg
            next
        }

        # ----- Assertions: parse PID, proc, action, type, named, held -----
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}.*Assertions/ {
            if (!match($0, /PID [0-9]+\(/)) next
            tail = substr($0, RSTART + 4)               # "127(powerd) Created ..."
            paren = index(tail, ")")
            pid  = substr(tail, 1, index(tail, "(") - 1)
            proc = substr(tail, index(tail, "(") + 1, paren - index(tail, "(") - 1)
            rest = substr(tail, paren + 2)              # "Created PreventUserIdleSystemSleep \"...\" 00:09:10 ..."
            # action verb
            if (!match(rest, /^(Created|Released|TimedOut|Summary)/)) next
            action = substr(rest, RSTART, RLENGTH)
            rest = substr(rest, RLENGTH + 2)
            # assertion type
            n = split(rest, parts, /[[:space:]]+/)
            atype = parts[1]
            # named: first quoted string
            name = "-"
            if (match($0, /"[^"]*"/)) name = substr($0, RSTART + 1, RLENGTH - 2)
            # held duration: pattern HH:MM:SS (last one wins — there is exactly one in the asserttion body)
            held = "-"
            t = $0
            while (match(t, / [0-9][0-9]:[0-9][0-9]:[0-9][0-9] /)) {
                held = substr(t, RSTART + 1, 8)
                t = substr(t, RSTART + RLENGTH)
            }

            # ---- normalize chatty per-channel names so dedupe can collapse them ----
            # coreaudiod registers one assertion per audio context; treat them
            # all as a single "audio playback" hold.
            if (proc == "coreaudiod" && name ~ /context[0-9]+\./) name = "audio playback"

            # ---- noise filters ----
            if (action == "Summary")  next     # mid-assertion progress; not state-changes
            # chatty types we never care about
            if (atype == "BackgroundTask")           next
            if (atype == "ApplePushServiceTask")     next
            if (atype == "InteractivePushServiceTask") next
            if (atype == "NetworkClientActive")      next
            if (atype == "UserIsActive")             next
            if (atype == "SystemIsActive")           next
            if (atype == "ExternalMedia")            next
            if (atype == "PreventUserIdleDisplaySleep") next   # too granular
            if (atype == "InternalPreventDisplaySleep") next

            # ---- classify ----

            # MaintenanceWake: dark wake for system housekeeping (TM, iCloud, ...)
            if (atype == "MaintenanceWake") {
                if (action == "Created")
                    printf "%s\tDARK-WAKE\tMaintenance darkwake started (by %s)\n",
                           ts($0), proc
                else if (action == "Released")
                    printf "%s\tDARK-WAKE\tMaintenance darkwake ended (held %s)\n",
                           ts($0), held
                next
            }

            # InternalPreventSleep "Holding in darkwake ..." — powerd hourly probe
            if (atype == "InternalPreventSleep" && name ~ /Holding in darkwake/) {
                if (action == "Created")
                    printf "%s\tDARK-PROBE\tDarkwake (powerd inactivity probe)\n",
                           ts($0)
                next                            # ignore the matching Released (instant)
            }

            # PreventSystemSleep: full sleep blocker. Skip WindowServer.DMGrace
            # (its DM-grace assertion is a brief hardware-debounce window, not user-meaningful).
            if (atype == "PreventSystemSleep") {
                if (name ~ /WindowServer\.DMGrace/) next
                v = action_verb(action)
                if (action == "Created")
                    printf "%s\tPREVENT\t%s %s blocking system sleep (\"%s\")\n",
                           ts($0), proc, v, name
                else
                    printf "%s\tPREVENT-END\t%s %s blocking system sleep (\"%s\", held %s)\n",
                           ts($0), proc, v, name, held
                next
            }

            # PreventUserIdleSystemSleep: skip the chatty powerd / "display is on" pair
            # (it duplicates the DISPLAY-ON/ DISPLAY-OFF notifications).
            if (atype == "PreventUserIdleSystemSleep") {
                if (proc == "powerd" && name ~ /Prevent sleep while display is on/) next
                v = action_verb(action)
                if (action == "Created")
                    printf "%s\tPREVENT\t%s %s preventing idle sleep (\"%s\")\n",
                           ts($0), proc, v, name
                else
                    printf "%s\tPREVENT-END\t%s %s preventing idle sleep (\"%s\", held %s)\n",
                           ts($0), proc, v, name, held
                next
            }

            # NoIdleSleep / NoDisplaySleep — caffeinate / explicit holds
            if (atype == "NoIdleSleepAssertion" || atype == "NoDisplaySleepAssertion") {
                v = action_verb(action)
                if (action == "Created")
                    printf "%s\tCAFFEINATE\t%s %s no-sleep hold (%s, \"%s\")\n",
                           ts($0), proc, v, atype, name
                else
                    printf "%s\tCAFFEINATE\t%s %s no-sleep hold (%s, held %s)\n",
                           ts($0), proc, v, atype, held
                next
            }

            # DisplayWake — typically NotificationCenter lighting the screen for a banner.
            # Skip the matching Released (uninteresting); keep Created and TimedOut.
            if (atype == "DisplayWake") {
                if (action == "Released") next
                printf "%s\tNOTIF-WAKE\tDisplay lit by %s (notification, \"%s\")\n",
                       ts($0), proc, name
                next
            }
        }
    ' "$_src"
}

action_wake_history() {
    _n="${WAKE_HISTORY_EVENTS:-10}"
    _tmp=$(mktemp 2>/dev/null || printf '/tmp/mpd.wh.%s' "$$")
    _ev="${_tmp}.events"
    _dd="${_tmp}.dedup"
    pmset -g log > "$_tmp" 2>/dev/null
    log_debug "pmset -g log: $(wc -l < "$_tmp" | tr -d ' ') lines captured to $_tmp"

    extract_power_events "$_tmp" > "$_ev"
    _raw_total=$(wc -l < "$_ev" | tr -d ' ')

    # Collapse adjacent identical (category, description) rows into one with
    # an (×N) multiplier and time-range. coreaudiod is normalised in the
    # extractor, but other bursts (e.g. ShipIt update sweeps) still benefit.
    awk -F'\t' '
        function emit(  span) {
            if (prev_cat == "") return
            if (n > 1) {
                # If first and last timestamps differ, show range.
                if (first_ts != last_ts)
                    printf "%s..%s\t%s\t%s (x%d)\n",
                           first_ts, substr(last_ts, 12), prev_cat, prev_desc, n
                else
                    printf "%s\t%s\t%s (x%d)\n",
                           first_ts, prev_cat, prev_desc, n
            } else {
                printf "%s\t%s\t%s\n", first_ts, prev_cat, prev_desc
            }
        }
        {
            if ($2 == prev_cat && $3 == prev_desc) {
                n++; last_ts = $1; next
            }
            emit()
            first_ts = $1; last_ts = $1; prev_cat = $2; prev_desc = $3; n = 1
        }
        END { emit() }
    ' "$_ev" > "$_dd"
    _dedup_total=$(wc -l < "$_dd" | tr -d ' ')

    printf '== last %s power events (oldest first; "*" marks a power-state change) ==\n' "$_n"
    if [ ! -s "$_dd" ]; then
        printf '  (no power events found in pmset log — log may be empty or in an unrecognised format)\n'
        rm -f "$_tmp" "$_ev" "$_dd"
        return 0
    fi

    # Format: " * YYYY-MM-DD HH:MM:SS  CATEGORY      description"
    tail -n "$_n" "$_dd" | awk -F'\t' '
        function flag(cat) {
            if (cat == "DISPLAY-ON")  return "*"
            if (cat == "DISPLAY-OFF") return "*"
            if (cat == "SLEEP"     )  return "*"
            if (cat == "WAKE"      )  return "*"
            if (cat == "HIBERNATE" )  return "*"
            if (cat == "DARK-WAKE" )  return "*"
            return " "
        }
        { printf "  %s  %-21s  %-11s  %s\n", flag($2), $1, $2, $3 }
    '

    printf '\n  (showing last %s of %s deduped events; %s raw events; %s pmset log lines)\n' \
        "$_n" "$_dedup_total" "$_raw_total" "$(wc -l < "$_tmp" | tr -d ' ')"
    printf '  (re-run with "%s wake-history-raw" for the underlying pmset log lines)\n' \
        "$PROG"

    rm -f "$_tmp" "$_ev" "$_dd"

    printf '\n== wake reasons (from unified log, last 24h, needs root for full data) ==\n'
    if is_root; then
        log show --last 24h --predicate \
            'eventMessage CONTAINS[c] "Wake reason"' \
            --style compact 2>/dev/null \
            | tail -n 30 \
            | sed 's/^/  /'
    else
        printf '  (run as root for full unified-log wake reasons)\n'
    fi
}

# Raw pmset log view — kept for when the narrative extractor is hiding
# something the user wants to see.
action_wake_history_raw() {
    printf '== sleep/wake history (last %s relevant pmset log lines) ==\n' \
        "$WAKE_HISTORY_LINES"
    pmset -g log 2>/dev/null \
        | grep -iE 'sleep|wake|darkwake|assertion|hibernat|battery' \
        | tail -n "$WAKE_HISTORY_LINES" \
        | sed 's/^/  /'
}

action_scheduled() {
    printf '== scheduled wakes (pmset -g sched) ==\n'
    pmset -g sched 2>/dev/null | sed 's/^/  /'
    printf '\n'
    printf '== power-related launchd plists with StartCalendarInterval ==\n'
    # Best-effort; doesn't require root, but coverage improves with it.
    for _d in /System/Library/LaunchDaemons /Library/LaunchDaemons \
              /System/Library/LaunchAgents /Library/LaunchAgents; do
        [ -d "$_d" ] || continue
        grep -l -E 'StartCalendarInterval|StartInterval' "$_d"/*.plist 2>/dev/null \
            | sed 's/^/  /'
    done
}

# ----------------------------------------------------------------------------
# KILL / PREVENT / RESTORE
# ----------------------------------------------------------------------------
# Selector matching against a single blocker row.
# Returns 0 on match. Selector "all" matches everything (excl. whitelist).
selector_matches() {
    _sel="$1"; _pid="$2"; _name="$3"; _label="$4"; _atype="$5"
    case "$_sel" in
        all) return 0 ;;
    esac
    [ "$_sel" = "$_pid" ] && return 0
    case "$_name"  in *"$_sel"*) return 0 ;; esac
    case "$_label" in *"$_sel"*) return 0 ;; esac
    case "$_atype" in *"$_sel"*) return 0 ;; esac
    return 1
}

# If SELECTOR is "#N" or pure digits, expand it via the appropriate cache.
# Mutates SELECTOR in place. Dies on resolution failure.
#
# Usage: expand_selector <action>
#   action = kill     -> resolve N from last-culprits cache, replace with PID
#   action = prevent  -> resolve N from last-culprits cache, replace with LABEL
#                        (or PID if no launchd label found)
#   action = restore  -> resolve N from state file (line N), replace with LABEL
expand_selector() {
    _act="$1"
    # Strip leading '#'
    case "$SELECTOR" in
        \#*) SELECTOR="${SELECTOR#\#}" ;;
    esac
    # Anything that isn't purely digits stays untouched.
    case "$SELECTOR" in
        ''|*[!0-9]*) return 0 ;;
    esac
    # 0 makes no sense (1-indexed)
    [ "$SELECTOR" -ge 1 ] 2>/dev/null \
        || die "selector '#$SELECTOR' must be >= 1"

    case "$_act" in
        restore)
            _sf=$(state_file)
            if [ ! -f "$_sf" ] || [ ! -s "$_sf" ]; then
                die "no state file — nothing has been prevented yet"
            fi
            _line=$(awk -F'\t' -v n="$SELECTOR" 'NR==n {print; exit}' "$_sf")
            [ -n "$_line" ] \
                || die "no entry #$SELECTOR in state file (use '$PROG state')"
            _new=$(printf '%s' "$_line" | cut -f2)
            [ -n "$_new" ] || die "state entry #$SELECTOR has no label"
            printf '%s: #%s -> label %s\n' "$PROG" "$SELECTOR" "$_new"
            SELECTOR="$_new"
            ;;
        kill|prevent)
            _cf=$(last_culprits_file)
            if [ ! -f "$_cf" ] || [ ! -s "$_cf" ]; then
                die "no culprits cache yet — run '$PROG culprits' first"
            fi
            _line=$(awk -F'\t' -v n="$SELECTOR" '$1==n {print; exit}' "$_cf")
            [ -n "$_line" ] \
                || die "no culprit #$SELECTOR in cache (run '$PROG culprits')"
            _c_pid=$(  printf '%s' "$_line" | cut -f2)
            _c_name=$( printf '%s' "$_line" | cut -f3)
            _c_label=$(printf '%s' "$_line" | cut -f4)
            if [ "$_act" = "kill" ]; then
                [ -n "$_c_pid" ] || die "culprit #$SELECTOR has no PID??"
                printf '%s: #%s -> pid %s (%s)\n' \
                    "$PROG" "$SELECTOR" "$_c_pid" "$_c_name"
                SELECTOR="$_c_pid"
            else
                # prevent: prefer label
                if [ -n "$_c_label" ]; then
                    printf '%s: #%s -> label %s (%s, pid %s)\n' \
                        "$PROG" "$SELECTOR" "$_c_label" "$_c_name" "$_c_pid"
                    SELECTOR="$_c_label"
                else
                    warn "culprit #$SELECTOR ($_c_name, pid $_c_pid) has no \
launchd label; 'prevent' won't persist. Use 'kill #$SELECTOR' for a \
one-shot stop instead."
                    die "cannot 'prevent' #$SELECTOR (no launchd label)"
                fi
            fi
            ;;
        *)
            die "expand_selector: unknown action '$_act'"
            ;;
    esac
}

# Ensure state dir exists.
ensure_state_dir() {
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "$STATE_DIR" 2>/dev/null \
            || die "cannot create state dir: $STATE_DIR"
    fi
}

state_file() {
    printf '%s/disabled.tsv' "$STATE_DIR"
}

# Where action_culprits caches the numbered row list so that
# 'prevent N' / 'kill N' can resolve.
last_culprits_file() {
    printf '%s/last-culprits.tsv' "$STATE_DIR"
}

# record_disabled  LABEL  DOMAIN  PID  NAME  ATYPE
record_disabled() {
    ensure_state_dir
    _sf=$(state_file)
    _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    # Don't duplicate (label,domain) pairs
    if [ -f "$_sf" ]; then
        if awk -F'\t' -v l="$1" -v d="$2" \
            'BEGIN{r=1} $2==l && $3==d {r=0} END{exit r}' "$_sf"; then
            return 0
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_ts" "$1" "$2" "$3" "$4" "$5" >> "$_sf"
}

# remove_disabled LABEL DOMAIN
remove_disabled() {
    _sf=$(state_file)
    [ -f "$_sf" ] || return 0
    _tmp="${_sf}.tmp.$$"
    awk -F'\t' -v l="$1" -v d="$2" '$2!=l || $3!=d' "$_sf" > "$_tmp" \
        && mv "$_tmp" "$_sf"
}

action_state() {
    _sf=$(state_file)
    printf '== prevented services (state file: %s) ==\n' "$_sf"
    if [ ! -f "$_sf" ] || [ ! -s "$_sf" ]; then
        printf '  (none recorded)\n'
        return 0
    fi
    printf '  %-3s %-25s %-40s %-12s %s\n' \
        '#' 'WHEN' 'LABEL' 'DOMAIN' 'WAS PROC/ASSERTION'
    awk -F'\t' '{
        printf "  #%-2d %-25s %-40s %-12s %s/%s\n", NR, $1, $2, $3, $5, $6
    }' "$_sf"
    printf '\n  (use "restore #N" or "restore <label>" to undo)\n'
}

# Iterate matching blockers and run a callback per row.
# usage: iterate_blockers SELECTOR CALLBACK
# CALLBACK receives: PID NAME LABEL DOMAIN ATYPE HELD ANAME
iterate_blockers() {
    _sel="$1"; _cb="$2"
    _rows=$(parse_assertions | filter_sleep_blockers all)
    if [ -z "$_rows" ]; then
        printf '%s: no sleep blockers active.\n' "$PROG"
        return 3
    fi
    _matched=0
    _hit=0
    # Use a temp file so subshell pipe doesn't lose counters.
    _tmp=$(mktemp 2>/dev/null || printf '/tmp/mpd.%s' $$)
    printf '%s\n' "$_rows" > "$_tmp"
    while IFS='	' read -r pid name atype held aname; do
        _ll=$(pid_to_launchd "$pid")
        label=$(printf '%s' "$_ll" | cut -f1)
        domain=$(printf '%s' "$_ll" | cut -f2)
        if ! selector_matches "$_sel" "$pid" "$name" "$label" "$atype"; then
            continue
        fi
        _matched=$((_matched + 1))
        # Whitelist applies to ALL selectors. --force is the explicit override
        # — when used, we still log loudly so the user sees what happened.
        if is_whitelisted "$pid" "$name" "$label" "$atype"; then
            if [ "$FORCE" -eq 1 ]; then
                printf '  [force: whitelist overridden] pid=%s name=%s label=%s atype=%s\n' \
                    "$pid" "$name" "${label:-?}" "$atype"
                log_debug "force-override whitelist: pid=$pid name=$name \
label=$label atype=$atype"
            else
                log_debug "skip whitelisted: pid=$pid name=$name label=$label atype=$atype"
                printf '  [skip-whitelist] pid=%s name=%s label=%s atype=%s (use --force to override)\n' \
                    "$pid" "$name" "${label:-?}" "$atype"
                continue
            fi
        fi
        _hit=$((_hit + 1))
        "$_cb" "$pid" "$name" "${label:-}" "${domain:-system}" \
               "$atype" "$held" "$aname"
    done < "$_tmp"
    rm -f "$_tmp"
    if [ "$_matched" -eq 0 ]; then
        printf '%s: selector "%s" matched nothing.\n' "$PROG" "$_sel"
        return 3
    fi
    if [ "$_hit" -eq 0 ]; then
        printf '%s: selector "%s" matched %s row(s), all whitelisted. \
Use --force to act on them.\n' \
            "$PROG" "$_sel" "$_matched"
        return 3
    fi
    return 0
}

# Callback: kill (one-shot)
_cb_kill() {
    _pid="$1"; _name="$2"; _label="$3"; _domain="$4"
    _atype="$5"; _held="$6"; _aname="$7"
    printf '  [kill] pid=%s name=%s label=%s (assertion=%s held=%s)\n' \
        "$_pid" "$_name" "${_label:-?}" "$_atype" "$_held"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '          (dry-run) would: kill %s\n' "$_pid"
        return 0
    fi
    if kill "$_pid" 2>/dev/null; then
        log_debug "killed pid=$_pid name=$_name"
    else
        warn "kill pid=$_pid failed (need root for system processes?)"
    fi
}

# Callback: prevent (persistent)
_cb_prevent() {
    _pid="$1"; _name="$2"; _label="$3"; _domain="$4"
    _atype="$5"; _held="$6"; _aname="$7"
    if [ -z "$_label" ]; then
        warn "no launchd label for pid=$_pid name=$_name — cannot 'prevent'. \
Use 'kill' to terminate this run only."
        return 1
    fi
    printf '  [prevent] label=%s domain=%s (pid=%s name=%s assertion=%s)\n' \
        "$_label" "$_domain" "$_pid" "$_name" "$_atype"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '            (dry-run) would: launchctl disable %s/%s\n' \
            "$_domain" "$_label"
        printf '            (dry-run) would: launchctl bootout  %s/%s\n' \
            "$_domain" "$_label"
        return 0
    fi
    # disable = persistent (survives reboot); bootout = stop now.
    if launchctl disable "${_domain}/${_label}" 2>/dev/null; then
        log_debug "launchctl disable ${_domain}/${_label} OK"
    else
        warn "launchctl disable ${_domain}/${_label} failed"
    fi
    if launchctl bootout "${_domain}/${_label}" 2>/dev/null; then
        log_debug "launchctl bootout ${_domain}/${_label} OK"
    else
        # Some labels can be disabled but not booted out (already gone, or no perms)
        log_debug "launchctl bootout ${_domain}/${_label} returned non-zero \
(may be already stopped)"
    fi
    record_disabled "$_label" "$_domain" "$_pid" "$_name" "$_atype"
}

action_kill() {
    [ -n "$SELECTOR" ] || die "kill: selector required (pid|name|label|#N|all)"
    expand_selector kill
    if [ "$SELECTOR" = "all" ] && [ "${MPD_YES:-0}" -ne 1 ]; then
        if [ "$FORCE" -eq 1 ]; then
            confirm "Kill ALL active sleep blockers INCLUDING WHITELISTED \
entries (--force)?" || die "aborted"
        else
            confirm "Kill ALL active (non-whitelisted) sleep blockers?" \
                || die "aborted"
        fi
    fi
    iterate_blockers "$SELECTOR" _cb_kill
}

action_prevent() {
    is_root || die "prevent requires root (launchctl disable system/*)"
    [ -n "$SELECTOR" ] || die "prevent: selector required (pid|name|label|#N|all)"
    expand_selector prevent
    if [ "$SELECTOR" = "all" ] && [ "${MPD_YES:-0}" -ne 1 ]; then
        if [ "$FORCE" -eq 1 ]; then
            confirm "Persistently disable ALL active sleep blockers \
INCLUDING WHITELISTED entries (--force)? They will NOT restart until \
'restore'." || die "aborted"
        else
            confirm "Persistently disable ALL active (non-whitelisted) sleep \
blockers? They will NOT restart until 'restore'." || die "aborted"
        fi
    fi
    iterate_blockers "$SELECTOR" _cb_prevent
}

action_restore() {
    is_root || die "restore requires root (launchctl enable system/*)"
    _sf=$(state_file)
    if [ ! -f "$_sf" ] || [ ! -s "$_sf" ]; then
        printf '%s: nothing to restore (state file empty).\n' "$PROG"
        return 3
    fi
    [ -n "$SELECTOR" ] || die "restore: selector required (label|#N|all)"
    expand_selector restore

    _tmp=$(mktemp 2>/dev/null || printf '/tmp/mpd.r.%s' $$)
    cp "$_sf" "$_tmp"
    _kept="${_sf}.tmp.$$"
    : > "$_kept"
    _n=0
    while IFS='	' read -r ts label domain pid name atype; do
        [ -n "$label" ] || continue
        _match=0
        if [ "$SELECTOR" = "all" ]; then
            _match=1
        else
            case "$label" in *"$SELECTOR"*) _match=1 ;; esac
            [ "$SELECTOR" = "$pid" ]  && _match=1
            case "$name" in *"$SELECTOR"*) _match=1 ;; esac
        fi
        if [ "$_match" -eq 0 ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$ts" "$label" "$domain" "$pid" "$name" "$atype" >> "$_kept"
            continue
        fi
        printf '  [restore] label=%s domain=%s\n' "$label" "$domain"
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '            (dry-run) would: launchctl enable    %s/%s\n' \
                "$domain" "$label"
            printf '            (dry-run) would: launchctl kickstart %s/%s\n' \
                "$domain" "$label"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$ts" "$label" "$domain" "$pid" "$name" "$atype" >> "$_kept"
            continue
        fi
        launchctl enable    "${domain}/${label}" 2>/dev/null \
            || warn "enable ${domain}/${label} failed"
        launchctl kickstart "${domain}/${label}" 2>/dev/null \
            || log_debug "kickstart ${domain}/${label} non-zero (may auto-start)"
        _n=$((_n + 1))
    done < "$_tmp"
    mv "$_kept" "$_sf"
    rm -f "$_tmp"
    printf '%s: restored %s service(s).\n' "$PROG" "$_n"
}

# ----------------------------------------------------------------------------
# ARG PARSING
# ----------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
            -D|--debug)   DEBUG=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -f|--force)   FORCE=1; shift ;;
            -y|--yes)     MPD_YES=1; shift ;;
            --config)
                [ $# -ge 2 ] || die "--config requires PATH"
                CONFIG_FILE_ARG="$2"; shift 2 ;;
            --config=*)
                CONFIG_FILE_ARG="${1#--config=}"; shift ;;
            --create-config)
                if [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
                    _p="$2"; shift 2
                    if [ -e "$_p" ]; then
                        die "$_p exists — refusing to overwrite \
(remove it manually first)"
                    fi
                    _dir=$(dirname "$_p")
                    [ -d "$_dir" ] || mkdir -p "$_dir" \
                        || die "cannot mkdir $_dir"
                    print_default_config > "$_p" \
                        && printf '%s: wrote default config to %s\n' \
                                  "$PROG" "$_p"
                    exit 0
                else
                    print_default_config
                    exit 0
                fi ;;
            --) shift; break ;;
            -*) die "unknown option: $1" ;;
            *)  break ;;
        esac
    done

    if [ $# -eq 0 ]; then
        ACTION="default"
    else
        ACTION="$1"; shift
        if [ $# -gt 0 ]; then
            SELECTOR="$1"; shift
        fi
        [ $# -eq 0 ] || die "trailing arguments: $*"
    fi
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    need_macos
    resolve_config
    load_config

    # If --config was used, announce resolved path.
    if [ -n "$CONFIG_FILE_ARG" ]; then
        printf '%s: using config: %s\n' "$PROG" "$CONFIG_FILE"
    fi

    log_debug "action=$ACTION selector=$SELECTOR config=${CONFIG_FILE:-none} \
debug=$DEBUG dry-run=$DRY_RUN force=$FORCE"

    case "$ACTION" in
        default)       action_default ;;
        status)        action_status ;;
        assertions)    action_assertions ;;
        culprits)      action_culprits ;;
        wake-history)     action_wake_history ;;
        wake-history-raw) action_wake_history_raw ;;
        scheduled)     action_scheduled ;;
        kill)          action_kill ;;
        prevent)       action_prevent ;;
        restore)       action_restore ;;
        state)         action_state ;;
        *)             usage >&2; die "unknown action: $ACTION" ;;
    esac
}

main "$@"
