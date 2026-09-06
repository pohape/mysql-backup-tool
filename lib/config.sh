# Configuration: a small DSL, not a pile of variables.
#
# A config file is a shell script that calls the functions below. That gives
# readable, self-documenting configs and lets the tool validate every setting
# as it is declared, instead of discovering a typo halfway through a dump.

# --- connection -------------------------------------------------------------
CFG_BACKEND=""
CFG_CONTAINER=""
CFG_COMPOSE_FILE=""
CFG_COMPOSE_SERVICE=""
CFG_HOST="127.0.0.1"
CFG_PORT="3306"
CFG_DB=""
CFG_USER=""
CFG_PASSWORD=""
CFG_CREDS_MODE=""          # env_file | container_env
CFG_ENV_FILE=""
CFG_ENV_KEY_DB=""
CFG_ENV_KEY_USER=""
CFG_ENV_KEY_PASSWORD=""
CFG_ENV_KEY_HOSTPORT=""

# --- repository -------------------------------------------------------------
CFG_REPO=""
CFG_REMOTE="origin"
CFG_BRANCH=""
CFG_SSH_KEY=""
CFG_PUSH_RETRIES=3

# --- layout -----------------------------------------------------------------
CFG_SCHEMA_FILE="schema.sql"
CFG_DATA_DIR="data"
declare -a CFG_TABLES_SCHEMA=()
declare -a CFG_TABLES_EXCLUDE=()
declare -a CFG_PARTITIONS=()

CFG_DUMP_BIN="mysqldump"
CFG_CLIENT_BIN="mysql"
declare -a CFG_DUMP_EXTRA=()

# --- policy -----------------------------------------------------------------
CFG_MIN_SIZE_RATIO=0       # optional floor: reject a dump below this % of its predecessor
CFG_DUMP_TIMEOUT=3600
CFG_FRESH_MAX_AGE=""       # seconds; required by `check-fresh`
CFG_GC_LOOSE_LIMIT=500     # run `git gc` once loose objects exceed this
CFG_NOTIFY_CMD=""

# Field separator for packed multi-field settings. ASCII Unit Separator cannot
# occur in a table name and will not occur in hand-written SQL.
readonly FS=$'\x1f'

# ---------------------------------------------------------------------------
# DSL
# ---------------------------------------------------------------------------

# database <name>
database() { CFG_DB=$1; }

# connect_native [--host H] [--port P]
connect_native() {
    CFG_BACKEND=native
    while [ $# -gt 0 ]; do
        case $1 in
            --host) CFG_HOST=$2; shift 2 ;;
            --port) CFG_PORT=$2; shift 2 ;;
            *) die "$EX_CONFIG" "connect_native: unknown option '$1'" ;;
        esac
    done
}

# connect_docker <container>
connect_docker() {
    CFG_BACKEND=docker
    CFG_CONTAINER=${1:?connect_docker requires a container name}
}

# connect_compose <compose-file> <service>
#
# Compose addresses a *service*, which is often not the container name. Both
# forms exist in the wild, so both are supported rather than guessed.
connect_compose() {
    CFG_BACKEND=compose
    CFG_COMPOSE_FILE=${1:?connect_compose requires a compose file}
    CFG_COMPOSE_SERVICE=${2:?connect_compose requires a service name}
}

# credentials_from_env_file <path> [--user KEY] [--password KEY]
#                                  [--database KEY] [--host-port KEY]
#
# Reads only the keys named here — never `source`s the file. A .env may hold
# unrelated definitions containing shell metacharacters, and sourcing it would
# execute them.
credentials_from_env_file() {
    CFG_CREDS_MODE=env_file
    CFG_ENV_FILE=${1:?credentials_from_env_file requires a path}; shift
    while [ $# -gt 0 ]; do
        case $1 in
            --user)      CFG_ENV_KEY_USER=$2;     shift 2 ;;
            --password)  CFG_ENV_KEY_PASSWORD=$2; shift 2 ;;
            --database)  CFG_ENV_KEY_DB=$2;       shift 2 ;;
            --host-port) CFG_ENV_KEY_HOSTPORT=$2; shift 2 ;;
            *) die "$EX_CONFIG" "credentials_from_env_file: unknown option '$1'" ;;
        esac
    done
}

# credentials_from_container_env [--user KEY] [--password KEY] [--database KEY]
#
# The strongest option available: the password is read inside the container
# from its own environment and never reaches the host — not the host's process
# table, not its filesystem, not this tool's memory.
credentials_from_container_env() {
    CFG_CREDS_MODE=container_env
    CFG_ENV_KEY_USER=MYSQL_USER
    CFG_ENV_KEY_PASSWORD=MYSQL_PASSWORD
    CFG_ENV_KEY_DB=MYSQL_DATABASE
    while [ $# -gt 0 ]; do
        case $1 in
            --user)     CFG_ENV_KEY_USER=$2;     shift 2 ;;
            --password) CFG_ENV_KEY_PASSWORD=$2; shift 2 ;;
            --database) CFG_ENV_KEY_DB=$2;       shift 2 ;;
            *) die "$EX_CONFIG" "credentials_from_container_env: unknown option '$1'" ;;
        esac
    done
}

# repository <dir> [--remote NAME] [--branch NAME] [--ssh-key PATH]
repository() {
    CFG_REPO=${1:?repository requires a directory}; shift
    while [ $# -gt 0 ]; do
        case $1 in
            --remote)  CFG_REMOTE=$2;  shift 2 ;;
            --branch)  CFG_BRANCH=$2;  shift 2 ;;
            --ssh-key) CFG_SSH_KEY=$2; shift 2 ;;
            *) die "$EX_CONFIG" "repository: unknown option '$1'" ;;
        esac
    done
}

# table_schema_only <name...>   — keep the structure, drop the rows
# table_exclude <name...>       — omit the table entirely
#
# There is deliberately no `table_data`: every table is backed up with its rows
# unless it is named here. A table added to the database next year is then
# protected from the first day, instead of being missed until someone
# remembers to update a whitelist. Say in a comment why anything is listed —
# an unexplained exclusion is indistinguishable from an accident when the
# config is read a year later.
table_schema_only() { CFG_TABLES_SCHEMA+=("$@"); }
table_exclude()     { CFG_TABLES_EXCLUDE+=("$@"); }

# partition <table> --dir DIR --list SQL --key COLUMN [--stable SQL]
#
# The heart of the method. Rather than dumping one table into one file that is
# rewritten on every change, split it along a column whose values have a
# one-way lifecycle — a session that converges, a tenant that closes, a day
# that ends. Each value gets its own file.
#
# Once a partition stops changing, its file becomes byte-identical forever.
# Git stores that blob once; every later commit adds zero bytes for it. This is
# what keeps a repository of hourly backups small for years.
#
#   --list   SQL returning two columns: the key value, and the filename stem.
#   --key    the column in <table> to match the key value against.
#   --stable SQL returning key values that can no longer change. Their files
#            are not re-dumped when they already exist. This is a load
#            optimisation only: a fresh dump would be byte-identical anyway.
#            Correctness never depends on it, which is why `verify` ignores it.
partition() {
    local table=${1:?partition requires a table}; shift
    local dir="" list="" key="" stable=""
    while [ $# -gt 0 ]; do
        case $1 in
            --dir)    dir=$2;    shift 2 ;;
            --list)   list=$2;   shift 2 ;;
            --key)    key=$2;    shift 2 ;;
            --stable) stable=$2; shift 2 ;;
            *) die "$EX_CONFIG" "partition: unknown option '$1'" ;;
        esac
    done
    [ -n "$dir" ]  || die "$EX_CONFIG" "partition $table: --dir is required"
    [ -n "$list" ] || die "$EX_CONFIG" "partition $table: --list is required"
    [ -n "$key" ]  || die "$EX_CONFIG" "partition $table: --key is required"
    CFG_PARTITIONS+=("${table}${FS}${dir}${FS}${list}${FS}${key}${FS}${stable}")
}

# client_binaries <dump-binary> <client-binary>
#
# MariaDB 11 renamed the tools to mariadb-dump/mariadb and deprecated the mysql*
# names; MySQL and older MariaDB still use mysqldump/mysql. Pin whichever the
# server image actually ships rather than hoping the compatibility symlink is
# still there.
client_binaries() {
    CFG_DUMP_BIN=${1:?client_binaries requires a dump binary}
    CFG_CLIENT_BIN=${2:?client_binaries requires a client binary}
}

# dump_option <arg...>
#
# Extra flags appended to every dump. Kept out of the defaults because they are
# not portable: --set-gtid-purged=OFF is MySQL-only and MariaDB rejects it.
dump_option() { CFG_DUMP_EXTRA+=("$@"); }

# schema_file <name>            — where the DDL goes (default schema.sql)
# data_dir <dir>                — subdirectory for flat per-table dumps
# freshness <seconds>           — deadline used by `check-fresh`
# min_size_ratio <percent>      — refuse a dump that shrank below this share of
#                                 the previous one. Off by default: truncation
#                                 is already caught precisely by the
#                                 completeness marker, and a table that
#                                 legitimately shrinks (a purge, an expiry job)
#                                 would otherwise fail the backup. Turn it on
#                                 for data that only ever grows.
# dump_timeout <seconds>
# gc_loose_limit <count>
# notify_command <command>
schema_file()    { CFG_SCHEMA_FILE=$1; }
data_dir()       { CFG_DATA_DIR=$1; }
freshness()      { CFG_FRESH_MAX_AGE=$1; }
min_size_ratio() { CFG_MIN_SIZE_RATIO=$1; }
dump_timeout()   { CFG_DUMP_TIMEOUT=$1; }
gc_loose_limit() { CFG_GC_LOOSE_LIMIT=$1; }
notify_command() { CFG_NOTIFY_CMD=$1; }

# docker_rootless <uid>
#
# Rootless Docker puts its socket under the user's runtime directory. cron does
# not read ~/.bashrc, so a script that works in an interactive shell fails from
# cron with "cannot connect to the Docker daemon" and nothing else to go on.
docker_rootless() {
    local uid=${1:-$(id -u)}
    export XDG_RUNTIME_DIR="/run/user/${uid}"
    export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
}

# ---------------------------------------------------------------------------
# .env reading
# ---------------------------------------------------------------------------

# env_value <file> <key>
#
# Tolerates what real .env files contain: an `export ` prefix, comments, blank
# lines, CRLF line endings from editors on Windows, and values wrapped in
# single or double quotes.
env_value() {
    local file=$1 key=$2
    [ -f "$file" ] || die "$EX_CONFIG" "env file not found: $file"
    local v
    v=$(awk -v key="$key" '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            eq = index(line, "=")
            if (eq == 0) next
            k = substr(line, 1, eq - 1)
            gsub(/[[:space:]]/, "", k)
            if (k != key) next
            v = substr(line, eq + 1)
            sub(/^[[:space:]]+/, "", v)
            if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/)
                v = substr(v, 2, length(v) - 2)
            print v
            found = 1
            exit
        }
        END { if (!found) exit 3 }
    ' "$file") || die "$EX_CONFIG" "key '$key' not found in $file"
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# loading and validation
# ---------------------------------------------------------------------------

load_config() {
    local path=$1
    [ -f "$path" ] || die "$EX_CONFIG" "config not found: $path"
    # shellcheck disable=SC1090
    . "$path"
    resolve_credentials
    validate_config
}

resolve_credentials() {
    case $CFG_CREDS_MODE in
        env_file)
            [ -n "$CFG_ENV_KEY_USER" ]     && CFG_USER=$(env_value "$CFG_ENV_FILE" "$CFG_ENV_KEY_USER")
            [ -n "$CFG_ENV_KEY_PASSWORD" ] && CFG_PASSWORD=$(env_value "$CFG_ENV_FILE" "$CFG_ENV_KEY_PASSWORD")
            [ -n "$CFG_ENV_KEY_DB" ]       && CFG_DB=$(env_value "$CFG_ENV_FILE" "$CFG_ENV_KEY_DB")
            if [ -n "$CFG_ENV_KEY_HOSTPORT" ]; then
                local hp; hp=$(env_value "$CFG_ENV_FILE" "$CFG_ENV_KEY_HOSTPORT")
                CFG_HOST=${hp%%:*}
                [ "$hp" = "$CFG_HOST" ] || CFG_PORT=${hp##*:}
            fi
            ;;
        container_env) : ;;  # resolved inside the container, at dump time
        "") die "$EX_CONFIG" "no credentials configured: call credentials_from_env_file or credentials_from_container_env" ;;
    esac
    return 0
}

validate_config() {
    [ -n "$CFG_BACKEND" ] || die "$EX_CONFIG" "no connection configured: call connect_native, connect_docker or connect_compose"
    [ -n "$CFG_REPO" ]    || die "$EX_CONFIG" "no repository configured: call repository <dir>"
    if [ "$CFG_CREDS_MODE" = container_env ] && [ "$CFG_BACKEND" = native ]; then
        die "$EX_CONFIG" "credentials_from_container_env requires a container backend"
    fi
    [ "$CFG_CREDS_MODE" = container_env ] || [ -n "$CFG_DB" ] || \
        die "$EX_CONFIG" "no database configured: call database <name> or map --database in credentials_from_env_file"
    case $CFG_MIN_SIZE_RATIO in ''|*[!0-9]*) die "$EX_CONFIG" "min_size_ratio must be an integer percentage" ;; esac
}
