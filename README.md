# mysql-backup-tool

Back up a MySQL or MariaDB database into a git repository, so that each run
stores a diff instead of another full copy.

A nightly `mysqldump | gzip` keeps N complete copies of a database that mostly
did not change. Committing the dump to git instead keeps every version, but
only if the dump is *deterministic* — if two dumps of unchanged data are
byte-identical. Getting that right is most of what this tool does.

Measured on a production deployment: a **2.4 GB database, backed up hourly for
three and a half months — 2349 commits — in a 171 MB repository**, with every
intermediate state recoverable.

## Why git

Git is not a general backup system, and this tool does not pretend otherwise.
It is very good at exactly one shape of data: text that changes a little at a
time. A SQL dump written one row per line is that shape.

**Use it for** the database itself — schema, configuration tables, business
records. You get every hourly state for months, a readable history of what
changed, cheap off-site replication over ssh, and restore from any point
without hunting for the right archive.

**Do not use it for** binary blobs, user uploads, or anything needing size-based
retention. Git cannot delta-compress opaque binaries and cannot forget: a 1 GB
file that changes daily costs 1 GB per day, forever. Use borg, restic or
similar for those, and this for the database.

## Install

One file. Clone it, or copy `mysql-backup` onto the server and make it
executable.

```sh
git clone https://github.com/pohape/mysql-backup-tool.git
```

Requirements: Linux, bash 4.0+, git, and the `mysql`/`mysqldump` client (or
`mariadb`/`mariadb-dump`) — either on the host or inside the database
container. Nothing else.

## Installing on a server

Clone the tool **once per server**, not once per database. It keeps no state of
its own: everything specific to a database lives in that database's config
file, and everything specific to a backup lives in that backup's repository.
Several databases on one machine share one copy of the tool.

Put it wherever your other checkouts live — the tool never looks at its own
location, and every path it touches comes from the config.

```
~/GitHub/mysql-backup-tool/   one clone, all databases
~/GitHub/shop/backup.conf     the config, living with the project it backs up
~/GitHub/crm/backup.conf
~/backups/shop/               one repository per database
~/backups/crm/
```

```cron
17 4 * * *  ~/GitHub/mysql-backup-tool/mysql-backup backup      ~/GitHub/shop/backup.conf >> ~/logs/shop-backup.log 2>&1
23 4 * * *  ~/GitHub/mysql-backup-tool/mysql-backup backup      ~/GitHub/crm/backup.conf  >> ~/logs/crm-backup.log  2>&1
 0 */6 * * * ~/GitHub/mysql-backup-tool/mysql-backup check-fresh ~/GitHub/shop/backup.conf
```

**Commit the config to the project it backs up.** It holds no secrets — only
the path of the `.env` and the names of the keys to read from it — and keeping
it there means the table list changes in the same commit as the migration that
added the table. Two rules make that safe: never write a password into the
config, and write paths relative to `$HOME` so the file still means the same
thing on the next machine.

Give each database its own remote repository. Sharing one between two databases
means two writers on one branch, and every push after the first is rejected.

### Pushing to a separate account

A deploy key belongs to a repository, not to an account, so backups can be
pushed into an account entirely separate from the one holding your code, with
no shared credentials: generate a key on the server, add it to the backup
repository with write access, and name it in the config.

```sh
ssh-keygen -t ed25519 -f ~/.ssh/shop_backup_deploy -N '' -C "$(hostname)-shop-backup"
# add the .pub to the backup repository -> Settings -> Deploy keys -> Allow write access
```

```sh
SSH_KEY="$HOME/.ssh/shop_backup_deploy"
REMOTE_URL=git@github.com:backup-account/shop-backup.git
```

If that separate account exists only to receive backups, GitHub asks that it be
a *machine account*: their terms allow one free personal account plus one free
machine account, used exclusively for automated tasks.

## Quick start

Write a config — plain shell variables (see `examples/`):

```sh
ENV_FILE="$HOME/myapp/.env"   # read the credentials from the app's own .env
ENV_USER_KEY=DB_USERNAME
ENV_PASSWORD_KEY=DB_PASSWORD
ENV_DATABASE_KEY=DB_DATABASE

REPO="$HOME/myapp-backup"                            # where it lives here
REMOTE_URL=git@github.com:you/myapp-backup.git       # where it is pushed
BRANCH=main
# SSH_KEY="$HOME/.ssh/myapp_backup_deploy"           # a dedicated deploy key

table_exclude sessions        # rebuilt on login; restoring them logs everyone out
table_schema_only audit_log   # keep the structure, drop the rows

FRESHNESS=90000               # daily, plus slack — used by check-fresh
```

If the database runs in a container, add `DB_CONTAINER=myapp-db` and the dump
runs inside it: the host needs no mysql client, and the database port does not
have to be exposed to the host.

Then create the backup repository and wire up its remote and deploy key:

```sh
./mysql-backup init myapp.conf
```

That is `git init`, the branch, `git remote add` and `core.sshCommand` in one
step, and it is safe to re-run. It also tries to reach the remote, so a deploy
key added without write access is caught now rather than at the first push.

Check everything before trusting it:

```sh
./mysql-backup doctor  myapp.conf   # config, connectivity, repository health
./mysql-backup verify  myapp.conf   # proves the dump is deterministic
./mysql-backup backup  myapp.conf   # the real thing
```

## Choosing which tables

By default every table is backed up and you name the exceptions:

```sh
table_exclude sessions        # not in the backup at all, structure included
table_schema_only audit_log   # structure kept, rows dropped
```

When most of a database is disposable — queues, caches, mail spools — and only
a few tables hold anything you would miss, turn it around:

```sh
TABLE_MODE=include
table_include orders customers invoices
```

A whitelist has one weakness: a table added later is not backed up, and nobody
finds out. So the tool prints the unlisted tables on **every** run —

```
include mode: 10 table(s) not listed, structure kept without rows: currency_rate incoming_email …
```

— and keeps their structure even though it drops their rows. Losing the rows
may be intended; losing the table definition never is.

Then from cron:

```cron
17 4 * * * /path/to/mysql-backup backup /path/to/myapp.conf >> /var/log/myapp-backup.log 2>&1
```

## How it stays small

Three mechanisms, in order of importance.

### 1. Deterministic output

`mysqldump` emits several things that change even when the data does not: the
dump date, the client and server version banners, and a table's
`AUTO_INCREMENT` counter, which advances on every insert and even on rollbacks.
Leave them in and every run rewrites the whole file — the repository then grows
by the size of the database, every time.

The tool dumps with `--skip-dump-date --order-by-primary --skip-extended-insert`
and strips the version banners and the `AUTO_INCREMENT` marker afterwards.
(Dropping the counter is safe: on restore MySQL sets it to `MAX(id)+1`.)
`--skip-extended-insert` puts one row per line, so a diff is "+3 rows" rather
than one rewritten mega-statement.

`mysql-backup verify` dumps everything twice and compares the results
byte-for-byte. If your setup breaks determinism, that command says so instead
of you discovering it from the disk graph six months later.

### 2. Partitioning by lifecycle

One file per table already helps: a change in one table does not touch the
others. For a table of millions of rows it is not enough, because a single new
row still rewrites the file.

Split it along a column whose values have a one-way lifecycle — a job that
finishes, an account that closes, a day that ends:

```sh
partition job_results --dir data/jobs \
    --list   "SELECT id, name FROM job_runs" \
    --key    run_id \
    --stable "SELECT id FROM job_runs WHERE state = 'finished'"
```

Each run gets `data/jobs/<name>.sql`. Once a run finishes, its file is
byte-identical forever: git stores that blob once, and every later commit adds
zero bytes for it. Only the active partitions produce diffs.

`--stable` is a load optimisation, not a correctness mechanism: files for
stable partitions are not re-dumped, because a fresh dump would be identical
anyway. Nothing depends on it being right — `verify` and `--no-skip` ignore it
entirely.

### 3. Packing

Git writes each new object as its own file and only delta-compresses when it
packs. Left alone, hourly backups pile up loose objects at full size. The tool
packs automatically once loose objects pass a threshold (`gc_loose_limit`,
default 500), and `mysql-backup gc` forces it.

This is not a marginal effect. In the incident that motivated the feature,
2897 loose objects occupied **5.64 GB**; the same content packed to **12.85 MB**.

## Commands

| Command | Purpose |
|---|---|
| `backup` | Dump, commit, push. The cron entry point. |
| `verify` | Dump twice, prove the output is identical. |
| `status` | One line for monitoring: it ran, and it reached the remote. |
| `doctor` | Everything that has to be true for tonight's backup to work. |
| `gc` | Repack now, ignoring the threshold. |

Options: `--no-skip` re-dumps every partition; `--dry-run` writes the files but
does not commit or push; `--allow-prune` permits a large deletion of files
whose rows are gone from the database.

That last one exists because deleting is the one thing that can destroy a
backup. If a run would remove more files than it keeps, it stops and asks
rather than guessing that you meant it.

Exit codes: `0` success (also "already running" and "nothing changed"),
`1` failure, `2` configuration error, `3` a dump failed validation,
`4` freshness deadline missed.

## Checking it before you trust it

`doctor` answers one question: will `backup` work when cron runs it tonight? It
exits non-zero if anything would stop it, so it can be run from a script.

```
$ ./mysql-backup doctor myapp.conf

environment
  ok    tools                  git, flock, timeout, awk
configuration
  ok    connection             docker exec myapp-db
  ok    credentials            container
  ok    table mode             exclude
  ok    freshness              1d 0h
repository
  ok    state                  writable, on branch main
  ok    remote read            git@github.com:you/myapp-backup.git
  ok    remote write           accepted
  ok    remote sync            in sync
database
  ok    connection             myapp
  ok    dump binary            mariadb-dump from 11.4.12-MariaDB
  ok    tables                 41
  ok    named tables           all exist
dumping
  ok    schema dump            33644 bytes
  ok    partition job_results  318 partition(s) into data/jobs/
history
  ok    last success           6h 12m ago

All checks passed.
```

Some of these are there because passing the obvious checks is not the same as
working:

- **remote write** does a `push --dry-run`. `ls-remote` only proves *read*
  access, and a deploy key added without write permission passes every other
  check and then fails at the first real push — which on a nightly job means
  tomorrow.
- **named tables** verifies that every table named in the config actually
  exists. A typo is otherwise silent, and silence here means a table you
  believe is excluded is being backed up, or one you believe is protected is
  not.
- **partition** runs each `--list` and `--stable` query, checks the names can
  be filenames, and checks that no two rows produce the same one. Those queries
  are otherwise only ever executed by `backup`, at four in the morning.
- **schema dump** performs a real dump with the configured flags, so missing
  privileges surface now rather than during the first backup.

## Monitor it, or it will fail silently

This is the failure mode that motivated the tool. A backup script ran hourly
for **two and a half months** without producing a single backup. The dump file
kept being rewritten with fresh data, so its timestamp always looked current.
Every check anyone was performing passed. The commit had been failing the whole
time — one earlier run as `root` had left the reflog root-owned, and the cron
user could no longer write it.

Two defences are built in:

**Preflight.** Before the first dump, `backup` verifies the repository is a git
repository, is not detached, and that its reflog is *actually writable* — by
writing to it. That specific check turns those two and a half months into one
loud error on the first run.

**A deadman switch.** Every successful run records a timestamp, and `status`
prints one line saying whether the backup is healthy:

```
$ ./mysql-backup status myapp.conf
BACKUP OK: last run 42m ago, pushed to origin/main
```

It checks two things, because freshness alone is not enough. A run can dump,
validate and commit perfectly and still fail to push — and then the backup
exists only on the machine it is meant to protect, while every freshness check
says all is well. So `status` also confirms the local branch matches the
remote:

```
BACKUP PROBLEM: 3 commit(s) not pushed to origin/main — the backup has not left this machine
BACKUP PROBLEM: last successful run 3d 4h ago, limit 1d 0h
BACKUP PROBLEM: no successful run has ever been recorded
```

It measures the last successful *run*, not the last commit: a database that
legitimately did not change must not look like a broken backup.

### Wiring it into a monitor

`status` exits non-zero on a problem and prints a single line, so it works with
anything that runs a command. With
[self-hosted-tg-alerts-uptime-monitor](https://github.com/pohape/self-hosted-tg-alerts-uptime-monitor)
— a small YAML-configured checker that sends Telegram alerts — add:

```yaml
  myapp_backup:
    command: "/home/user/GitHub/mysql-backup-tool/mysql-backup status /home/user/GitHub/myapp/backup.conf"
    search_string: "BACKUP OK"
    schedule: "0 */6 * * *"
    notify_after_attempt: 2
    timeout: 60
    tg_chats_to_notify:
      - 123456789
```

`notify_after_attempt: 2` keeps a momentary network failure from paging you:
an unreachable remote is a problem worth knowing about, but not on the first
try. Or from plain cron, relying on the exit code:

```cron
0 */6 * * * /path/to/mysql-backup status /path/to/myapp.conf || mail -s "backup problem" you@example.com
```

## Restoring

The dump is ordinary SQL. Load the schema first, then the data:

```sh
mysql mydb < schema.sql
find data -name '*.sql' | sort | xargs cat | mysql mydb
```

Practise this before you need it. A backup you have never restored is a
hypothesis, not a backup — and this applies to the repository you are reading
about right now.

## Hardening the receiver

If you push to your own server rather than a hosted service, make the receiving
repository append-only, so a compromised database host cannot erase its own
backup history:

```sh
git init --bare /srv/backup/myapp.git
git -C /srv/backup/myapp.git config receive.denyNonFastForwards true
git -C /srv/backup/myapp.git config receive.denyDeletes true
```

Restrict the ssh key to that repository, and this tool will never fight it: it
does not force-push, ever. A rejected push is reported as an error for a human
to resolve, because on an append-only receiver a force push is precisely the
operation an attacker needs.

## Credentials

The password is never passed as a command-line argument — not to `mysqldump`,
and not to `docker` either, since `docker exec -e SECRET=...` is just as visible
in `ps`. Depending on the setup it travels one of three ways:

- **local client** — as an environment variable on the dump process only;
- **container** — over stdin, into a shell inside the container;
- **`CREDS_IN_CONTAINER=1`** — never at all: the dump reads it from the
  container's own environment, and the host never holds it.

Keep config files out of version control. The shipped `.gitignore` excludes
`*.conf` for exactly that reason.

## Limitations

- InnoDB is assumed. `--single-transaction` gives a consistent snapshot without
  locking; MyISAM tables will not be consistent with each other.
- Very wide binary columns work but defeat the point — git cannot diff them.
- The tool never rewrites history, so the repository grows for as long as you
  keep it. With deterministic dumps that growth is proportional to how much your
  data actually changes, which is the intent.

## License

MIT — see [LICENSE](LICENSE).
