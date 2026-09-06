# Producing files that git can store cheaply.
#
# Two independent jobs live here. Canonicalisation removes the parts of
# mysqldump's output that change even when the data does not; without it every
# run rewrites the whole file and the repository grows by its full size each
# time. Atomic publication makes sure a failed dump can never replace a good
# backup — the single most common way these scripts destroy the thing they are
# meant to protect.

declare -A EXPECTED=()   # every path this run is allowed to leave behind

# The last line mysqldump writes. Its presence proves the dump ran to
# completion — a far more precise truncation test than any size heuristic,
# and it holds even for a dump that legitimately contains no rows at all.
readonly DUMP_COMPLETE_MARKER='SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT'

# ---------------------------------------------------------------------------
# safety of values that come from the database
# ---------------------------------------------------------------------------

# sanitise_name <string>
#
# Partition names become filenames. A name holding a slash or `..` would write
# outside the repository, so anything but a conservative character set is
# rejected rather than mangled: silently renaming a partition would detach its
# file from its data.
sanitise_name() {
    local n=$1
    case $n in
        ''|.|..)      return 1 ;;
        -*)           return 1 ;;   # would be read as an option elsewhere
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    printf '%s' "$n"
}

# sql_quote <string> — a single-quoted SQL literal, safely escaped.
sql_quote() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\'/\\\'}
    printf "'%s'" "$s"
}

# ---------------------------------------------------------------------------
# canonicalisation
# ---------------------------------------------------------------------------

# canonicalise <file>
#
# Removes exactly two kinds of run-to-run noise, and nothing else:
#
#   1. Version banners. `-- MySQL dump 10.13 Distrib 8.4.0...` and
#      `-- Server version 8.4.0` change when either the client or the server is
#      upgraded, which would otherwise produce one enormous meaningless diff
#      across every file at once. (The dump date is already gone: the dump runs
#      with --skip-dump-date.)
#
#   2. `AUTO_INCREMENT=N` in a table's closing line. This counter advances on
#      every insert — and on rollbacks and restarts, even when no row changed.
#      Dropping it is safe: on restore MySQL sets the counter to MAX(id)+1.
#
# Patterns are anchored tightly on purpose. A blanket "delete every line
# starting with --" is shorter, but a text column containing a newline followed
# by "-- " would then lose that line: silent data corruption inside a backup.
canonicalise() {
    local file=$1 tmp="$1.canon"
    awk '
        /^-- (MySQL|MariaDB) dump / { next }
        /^-- Server version/        { next }
        /^-- Dump completed/        { next }
        /^\) ENGINE=/               { gsub(/ AUTO_INCREMENT=[0-9]+/, "") }
        { print }
    ' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

# validate_dump <file> <expect-marker> [previous-file]
#
# A truncated dump is not empty, so a size test alone passes it. Three checks:
# the file has content, it contains the marker that proves the dump reached the
# part we care about, and it has not collapsed relative to the previous good
# version.
validate_dump() {
    local file=$1 marker=$2 prev=${3:-}

    [ -s "$file" ] || { warn "dump is empty: $file"; return 1; }

    if ! grep -q "$marker" "$file"; then
        warn "dump lacks expected marker '$marker': $file"
        return 1
    fi

    if [ "$CFG_MIN_SIZE_RATIO" -gt 0 ] && [ -n "$prev" ] && [ -f "$prev" ]; then
        local new old floor
        new=$(stat -c%s "$file")
        old=$(stat -c%s "$prev")
        floor=$(( old * CFG_MIN_SIZE_RATIO / 100 ))
        if [ "$new" -lt "$floor" ]; then
            warn "dump shrank to ${new}B from ${old}B (floor ${floor}B, ${CFG_MIN_SIZE_RATIO}%): $file"
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# atomic publication
# ---------------------------------------------------------------------------

# dump_to <destination> <expect-marker> <dump-args...>
#
# Writes to a temporary file, canonicalises it, validates it, and only then
# replaces the destination. If any step fails the previous backup is still
# there, untouched.
dump_to() {
    local dest=$1 marker=$2; shift 2
    local tmp="${dest}.tmp"

    # Two partitions resolving to the same filename would silently overwrite
    # each other and leave one partition's data missing from the backup.
    if [ -n "${EXPECTED[$dest]:-}" ]; then
        die "$EX_CONFIG" "two partitions both map to '$dest'; make the --list query return unique names"
    fi

    mkdir -p "$(dirname "$dest")"
    # shellcheck disable=SC2064
    trap "rm -f $(printf '%q' "$tmp")" RETURN

    if ! db_dump "$@" > "$tmp"; then
        warn "dump failed for $dest (previous version kept)"
        return 1
    fi

    canonicalise "$tmp"
    validate_dump "$tmp" "$marker" "$dest" || return 1

    mv -f "$tmp" "$dest"
    EXPECTED["$dest"]=1
    return 0
}

# expect <path...> — mark files this run intends to keep, without dumping them.
expect() {
    local p
    for p in "$@"; do EXPECTED["$p"]=1; done
}

# remove_orphans <dir...>
#
# A partition renamed or deleted in the database must not leave its stale file
# behind: a backup that keeps resurrecting deleted data is not a backup of the
# database, it is a backup of everything the database ever contained.
remove_orphans() {
    local dir f removed=0

    # A guard against the worst failure this tool could have. Orphan removal
    # deletes every file the run did not register, so if the run registered
    # nothing — because a listing query failed, or a config change emptied the
    # table set — this would delete the entire backup and then commit the
    # deletion. Callers already fail loudly on a failed query; this is the
    # second line of defence.
    if [ "${#EXPECTED[@]}" -eq 0 ]; then
        warn "no files were produced; skipping orphan removal"
        return 0
    fi
    for dir in "$@"; do
        [ -d "$dir" ] || continue
        while IFS= read -r -d '' f; do
            if [ -z "${EXPECTED[$f]:-}" ]; then
                rm -f "$f"
                removed=$(( removed + 1 ))
            fi
        done < <(find "$dir" -type f -name '*.sql' -print0)
    done
    [ "$removed" -eq 0 ] || log "removed $removed orphaned file(s)"
}
