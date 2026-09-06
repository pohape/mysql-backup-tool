# Logging and exit codes.
#
# Every line carries a UTC timestamp: a backup log without timestamps cannot
# answer "when did this stop working", which is the only question that matters
# once a backup has silently died.

EX_OK=0          # success, something was backed up
EX_FAIL=1        # generic failure
EX_CONFIG=2      # the configuration is wrong; retrying will not help
EX_VALIDATION=3  # a dump was produced but failed its sanity checks
EX_STALE=4       # freshness deadline missed (check-fresh only)

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log()  { printf '%s %s\n'      "$(_ts)" "$*"; }
warn() { printf '%s WARN %s\n' "$(_ts)" "$*" >&2; }

# die <exit-code> <message...>
die() {
    local code=$1; shift
    printf '%s FATAL %s\n' "$(_ts)" "$*" >&2
    notify "FAILED: $*"
    exit "$code"
}

# Optional external notifier, configured with `notify_command`. It receives the
# message as its single argument. Failures here are logged, never fatal: a
# broken notifier must not take the backup down with it.
notify() {
    [ -n "${CFG_NOTIFY_CMD:-}" ] || return 0
    "$CFG_NOTIFY_CMD" "$1" || warn "notify_command failed (exit $?)"
}
