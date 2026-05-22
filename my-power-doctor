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
VERSION="1.0.0"

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
    (no action)             Default. Active sleep blockers + prevented state.
    status                  Verbose overview: settings, scheduled wakes, culprits.
    assertions              Full parsed dump of pmset -g assertions.
    culprits                Compact list of PID/name/label/assertion.
    wake-history            Recent sleep/wake events & wake reasons.
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
# Default action when no verb is given: the two pieces that answer
# "is anything blocking sleep right now?" and "what have I disabled?".
action_default() {
    action_culprits
    printf '\n'
    action_state
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

    printf '== last wake reason ==\n'
    pmset -g log 2>/dev/null \
        | grep -iE 'wake[[:space:]]+(reason|from)' \
        | tail -n 5 \
        | sed 's/^/  /'
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

action_wake_history() {
    printf '== sleep/wake history (last %s relevant log lines) ==\n' \
        "$WAKE_HISTORY_LINES"
    pmset -g log 2>/dev/null \
        | grep -iE 'sleep|wake|darkwake|assertion' \
        | tail -n "$WAKE_HISTORY_LINES" \
        | sed 's/^/  /'
    printf '\n'
    printf '== wake reasons (from unified log, last 24h, needs root for full data) ==\n'
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
        wake-history)  action_wake_history ;;
        scheduled)     action_scheduled ;;
        kill)          action_kill ;;
        prevent)       action_prevent ;;
        restore)       action_restore ;;
        state)         action_state ;;
        *)             usage >&2; die "unknown action: $ACTION" ;;
    esac
}

main "$@"
