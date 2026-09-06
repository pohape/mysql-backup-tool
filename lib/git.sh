# The git side of the backup.
#
# Everything here exists because of a failure that actually happened. The
# preflight check exists because one deployment ran the backup once as root,
# left .git/logs owned by root, and then failed on every subsequent cron run
# for two and a half months while the dump file kept being refreshed — the
# backup looked alive by every signal anyone was watching. The gc discipline
# exists because those failed runs left one unreachable 25 MB object per hour:
# 5.7 GB of garbage for a 24 MB database.

# git_current_branch — the checked-out branch, working before the first commit.
#
# `rev-parse --abbrev-ref HEAD` fails on a repository with no commits yet and
# helpfully prints the literal string "HEAD", which then propagates as if it
# were a branch name. symbolic-ref answers correctly from the very first run.
git_current_branch() {
    git_in_repo symbolic-ref --short -q HEAD
}

# git_head_sha — HEAD's commit, or empty before the first commit.
git_head_sha() {
    git_in_repo rev-parse --verify --quiet HEAD || true
}

# git_in_repo <args...> — run git against the configured repository.
git_in_repo() {
    git -C "$CFG_REPO" "$@"
}

# git_setup — configure the repository for unattended use. Idempotent.
git_setup() {
    git_in_repo config user.name  >/dev/null 2>&1 || git_in_repo config user.name  "mysql-backup-tool"
    git_in_repo config user.email >/dev/null 2>&1 || git_in_repo config user.email "mysql-backup-tool@localhost"

    # A dedicated key configured in the repository, rather than a host alias in
    # ~/.ssh/config, keeps the deployment self-contained: nothing outside this
    # directory has to be edited for the push to work.
    if [ -n "$CFG_SSH_KEY" ]; then
        git_in_repo config core.sshCommand \
            "ssh -i $CFG_SSH_KEY -o IdentitiesOnly=yes"
    fi
}

# git_preflight — refuse to start unless the repository can actually be written.
#
# Checked before the first dump, so a broken receiver costs one clear error
# instead of months of silent failure.
git_preflight() {
    [ -d "$CFG_REPO" ] || die "$EX_CONFIG" "repository directory does not exist: $CFG_REPO"
    git_in_repo rev-parse --git-dir >/dev/null 2>&1 || die "$EX_CONFIG" "not a git repository: $CFG_REPO"

    git_in_repo symbolic-ref -q HEAD >/dev/null 2>&1 || \
        die "$EX_CONFIG" "HEAD is detached in $CFG_REPO; commits would go nowhere"

    # The write test that would have caught the two-month outage. `git add`
    # succeeds on a repository whose reflog is unwritable; `git commit` does
    # not. Probing the reflog directory directly turns that into an immediate,
    # explicit failure.
    local gitdir logs probe
    gitdir=$(git_in_repo rev-parse --absolute-git-dir)
    logs="$gitdir/logs"
    mkdir -p "$logs" 2>/dev/null || die "$EX_CONFIG" "cannot create $logs"
    probe="$logs/.write-probe.$$"
    if ! : > "$probe" 2>/dev/null; then
        die "$EX_CONFIG" "cannot write to $logs — commits will fail. Check ownership (a run as root leaves root-owned reflogs)"
    fi
    rm -f "$probe"

    [ -w "$gitdir" ] || die "$EX_CONFIG" "git directory is not writable: $gitdir"

    if [ -n "$CFG_REMOTE" ] && ! git_in_repo remote get-url "$CFG_REMOTE" >/dev/null 2>&1; then
        die "$EX_CONFIG" "remote '$CFG_REMOTE' is not configured in $CFG_REPO"
    fi
}

# git_commit <pathspec...> — commit whatever changed, or report that nothing did.
#
# Returns 0 and prints nothing to commit when the working tree is clean; the
# caller decides whether that is success. Errors are never swallowed: a commit
# that fails must not be reported as a completed backup.
git_commit() {
    # Checked explicitly: if `add` fails and we fall through, the index looks
    # unchanged and the run reports "nothing to back up" — the most dangerous
    # possible way for a backup to fail.
    git_in_repo add -A -- "$@" || { warn "git add failed"; return 1; }

    if git_in_repo diff --cached --quiet; then
        log "no changes"
        return 10
    fi

    local stat
    stat=$(git_in_repo diff --cached --shortstat | sed 's/^ *//')
    # The commit date is already in the commit metadata; repeating it in the
    # subject wastes the one line that could say what actually changed.
    git_in_repo commit -q -m "backup: $stat" || return 1
    log "committed: $stat"
    return 0
}

# git_push — push with retries, and verify the remote actually moved.
#
# A push can report success and still leave the remote behind if something in
# between lies; and a non-fast-forward means the histories diverged, which is
# never solved by forcing. Forcing is the one thing this tool must never do:
# on an append-only receiver it is exactly the operation an attacker needs.
git_push() {
    local branch=${CFG_BRANCH:-$(git_current_branch)}
    local attempt=1 delay=5

    while [ "$attempt" -le "$CFG_PUSH_RETRIES" ]; do
        local out rc
        out=$(git_in_repo push "$CFG_REMOTE" "HEAD:refs/heads/$branch" 2>&1); rc=$?

        if [ $rc -eq 0 ]; then
            local local_sha remote_sha
            local_sha=$(git_head_sha)
            remote_sha=$(git_in_repo ls-remote "$CFG_REMOTE" "refs/heads/$branch" | cut -f1)
            if [ "$local_sha" = "$remote_sha" ]; then
                log "pushed to $CFG_REMOTE/$branch"
                return 0
            fi
            warn "push reported success but $CFG_REMOTE/$branch is at ${remote_sha:-<missing>}, expected $local_sha"
            return 1
        fi

        if printf '%s' "$out" | grep -qi 'non-fast-forward\|fetch first\|rejected'; then
            warn "push rejected — the remote has commits this repository does not."
            warn "Resolve by hand: this tool never force-pushes, because on an"
            warn "append-only receiver a force push is how backups get destroyed."
            printf '%s\n' "$out" >&2
            return 1
        fi

        warn "push attempt $attempt/$CFG_PUSH_RETRIES failed, retrying in ${delay}s"
        sleep "$delay"
        attempt=$(( attempt + 1 ))
        delay=$(( delay * 2 ))
    done

    warn "push failed after $CFG_PUSH_RETRIES attempts"
    printf '%s\n' "${out:-}" >&2
    return 1
}

# git_loose_count — objects not yet packed.
git_loose_count() {
    git_in_repo count-objects -v | awk '/^count:/ { print $2 }'
}

# git_maintain — pack loose objects once they accumulate.
#
# Git writes every new object as its own file and only delta-compresses when
# packing. Left alone, hourly backups of a large table pile up loose objects at
# full size. Packing is what turns that into a diff-sized repository, and the
# difference is not marginal: in the incident that motivated this function,
# 2897 loose objects occupied 5.64 GB while the same content packed to 12.85 MB.
git_maintain() {
    local loose
    loose=$(git_loose_count)
    if [ "${loose:-0}" -lt "$CFG_GC_LOOSE_LIMIT" ]; then
        return 0
    fi
    log "packing $loose loose objects"
    if git_in_repo gc --quiet --prune=now; then
        log "packed; $(git_loose_count) loose objects remain"
    else
        warn "git gc failed"
    fi
}

# git_last_commit_age — seconds since the newest commit, or empty if none.
git_last_commit_age() {
    local ts now
    ts=$(git_in_repo log -1 --format=%ct 2>/dev/null) || return 1
    [ -n "$ts" ] || return 1
    now=$(date +%s)
    printf '%s' "$(( now - ts ))"
}
