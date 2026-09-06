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

```sh
git clone https://github.com/pohape/mysql-backup-tool.git
```

Requirements: bash 4.3+, git, and the `mysql`/`mysqldump` client (or
`mariadb`/`mariadb-dump`) — either on the host or inside the database container.
No other dependencies.

## Quick start

Create the repository that will hold the backups:

```sh
git init ~/myapp-backup
cd ~/myapp-backup && git remote add origin git@github.com:you/myapp-backup.git
```

Write a config (see `examples/`):

```sh
connect_native --host 127.0.0.1 --port 3306

credentials_from_env_file "$HOME/myapp/.env" \
    --user DB_USERNAME --password DB_PASSWORD --database DB_DATABASE

repository "$HOME/myapp-backup" --branch main

table_exclude sessions        # rebuilt on login; restoring them logs everyone out
table_schema_only audit_log   # keep the structure, drop the rows

freshness 90000               # daily, plus slack — used by check-fresh
```

Check everything before trusting it:

```sh
mysql-backup doctor  myapp.conf     # config, connectivity, repository health
mysql-backup verify  myapp.conf     # proves the dump is deterministic
mysql-backup backup  myapp.conf     # the real thing
```

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
| `check-fresh` | Report time since the last success; non-zero when overdue. |
| `doctor` | Config, connectivity, repository and remote health. |
| `gc` | Repack now, ignoring the threshold. |

Options: `--no-skip` re-dumps every partition; `--dry-run` writes the files but
does not commit or push.

Exit codes: `0` success (also "already running" and "nothing changed"),
`1` failure, `2` configuration error, `3` a dump failed validation,
`4` freshness deadline missed.

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

**A deadman switch.** Every successful run records a timestamp.
`check-fresh` compares it against `freshness` and exits non-zero when the
deadline passes, printing `FRESH` or `STALE`:

```cron
0 */6 * * * /path/to/mysql-backup check-fresh /path/to/myapp.conf
```

It measures the last successful *run*, not the last commit — a database that
legitimately did not change must not look like a broken backup.

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

- **native** — as an environment variable on the dump process only;
- **container** — over stdin, into a shell inside the container;
- **container_env** — never at all: the dump reads it from the container's own
  environment, and the host never holds it.

Keep config files out of version control. The shipped `.gitignore` excludes
`*.conf` for exactly that reason.

## Limitations

- InnoDB is assumed. `--single-transaction` gives a consistent snapshot without
  locking; MyISAM tables will not be consistent with each other.
- Very wide binary columns work but defeat the point — git cannot diff them.
- The tool never rewrites history, so the repository grows for as long as you
  keep it. With deterministic dumps that growth is proportional to how much your
  data actually changes, which is the intent.
