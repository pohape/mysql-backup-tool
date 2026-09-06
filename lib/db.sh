# Database access.
#
# One rule governs this file: the password never appears in a command line.
# Anything in argv is visible to every user on the host through `ps`, and that
# includes the arguments of `docker exec`, not just of mysqldump itself.
#
# Three transports, one discipline:
#   native        — MYSQL_PWD is set as a command prefix, so it lives in the
#                   process environment and never in its arguments.
#   container     — the dump runs under `sh -c` inside the container and reads
#                   the password from stdin. Neither the host's process table
#                   nor the container's ever sees it.
#   container_env — better still: the password is read from the container's own
#                   environment and never leaves it at all.

# Flags every dump gets. The first three are about consistency and memory; the
# rest are what make two dumps of unchanged data byte-identical, which is the
# entire premise of storing backups in git.
DUMP_DEFAULTS=(
    --single-transaction          # consistent InnoDB snapshot without locking
    --quick                       # stream rows instead of buffering the table
    --no-tablespaces              # avoids needing the PROCESS privilege
    --skip-extended-insert        # one row per line, so diffs are line-level
    --order-by-primary            # stable row order across runs
    --skip-dump-date              # no "Dump completed on <date>" to churn
    --default-character-set=utf8mb4
)

# Quote a string for safe inclusion in a `sh -c` command.
_shq() {
    local s=${1//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

_container_exec() {
    case $CFG_BACKEND in
        docker)
            timeout "$CFG_DUMP_TIMEOUT" docker exec -i "$CFG_CONTAINER" "$@"
            ;;
        compose)
            timeout "$CFG_DUMP_TIMEOUT" docker compose -f "$CFG_COMPOSE_FILE" \
                exec -T "$CFG_COMPOSE_SERVICE" "$@"
            ;;
    esac
}

# _run_client <binary> <args...>
#
# The literal token @DB@ in the arguments is replaced by the database name,
# which in container_env mode is only known inside the container.
_run_client() {
    local bin=$1; shift

    if [ "$CFG_BACKEND" = native ]; then
        local -a args=()
        local x
        for x in "$@"; do
            if [ "$x" = "@DB@" ]; then args+=("$CFG_DB"); else args+=("$x"); fi
        done
        MYSQL_PWD="$CFG_PASSWORD" timeout "$CFG_DUMP_TIMEOUT" "$bin" \
            -h"$CFG_HOST" -P"$CFG_PORT" -u"$CFG_USER" "${args[@]}"
        return
    fi

    local cmd x
    if [ "$CFG_CREDS_MODE" = container_env ]; then
        cmd="export MYSQL_PWD=\"\$${CFG_ENV_KEY_PASSWORD}\"; exec $(_shq "$bin") -u\"\$${CFG_ENV_KEY_USER}\""
        for x in "$@"; do
            if [ "$x" = "@DB@" ]; then
                cmd+=" \"\$${CFG_ENV_KEY_DB}\""
            else
                cmd+=" $(_shq "$x")"
            fi
        done
        # stdin is closed explicitly: `docker exec -i` inherits it, and a
        # caller invoked from a script would otherwise have the rest of that
        # script silently eaten by the container.
        _container_exec sh -c "$cmd" < /dev/null
    else
        cmd="IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec $(_shq "$bin") -u$(_shq "$CFG_USER")"
        for x in "$@"; do
            if [ "$x" = "@DB@" ]; then
                cmd+=" $(_shq "$CFG_DB")"
            else
                cmd+=" $(_shq "$x")"
            fi
        done
        printf '%s\n' "$CFG_PASSWORD" | _container_exec sh -c "$cmd"
    fi
}

# db_query <sql> — tab-separated rows, no header, no column framing.
db_query() {
    _run_client "$CFG_CLIENT_BIN" -N -B -e "$1" @DB@
}

# db_dump <options...> [-- <tables...>] — dump to stdout.
db_dump() {
    local -a opts=() tables=()
    local sep=0 a
    for a in "$@"; do
        if [ "$a" = "--" ] && [ $sep -eq 0 ]; then sep=1; continue; fi
        if [ $sep -eq 1 ]; then tables+=("$a"); else opts+=("$a"); fi
    done
    _run_client "$CFG_DUMP_BIN" \
        "${DUMP_DEFAULTS[@]}" "${CFG_DUMP_EXTRA[@]+"${CFG_DUMP_EXTRA[@]}"}" \
        "${opts[@]+"${opts[@]}"}" @DB@ "${tables[@]+"${tables[@]}"}"
}

# db_tables — every base table in the database, one per line.
#
# Views are excluded: mysqldump emits them as part of the schema, and dumping
# their "rows" would duplicate data that already lives in the source tables.
db_tables() {
    db_query "SELECT table_name
              FROM information_schema.tables
              WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'
              ORDER BY table_name"
}

# db_check — prove the connection works before anything destructive happens.
db_check() {
    local got
    got=$(db_query "SELECT 1") || return 1
    [ "$got" = "1" ]
}
