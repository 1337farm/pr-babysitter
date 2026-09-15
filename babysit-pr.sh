#!/usr/bin/env bash
# babysit-pr.sh — poll a PR until its checks resolve, then report.
#
# Babysitting means polling, not hoping: this script watches a PR's checks
# until they complete, reports failures/blockers with run URLs, and exits
# nonzero unless the PR is green (or merged). Run it, then fix what it
# reports, then run it again — that is the loop.
#
# Repo-specific values come from .babysitrc in the current repo root
# (KEY=VALUE lines; see .babysitrc.example). CLI flags override the file;
# flags override nothing when absent. No repo-specific defaults are baked
# in — an unset value fails loudly at the phase that needs it.
#
# Usage:
#   babysit-pr.sh <PR> [interval_sec=60] [max_polls=60] [--apk[=dir]] [--latest-apk[=dir]] [--pr-apk[=dir]] [--prune=dir] [--no-prune]
#                 [--artifact=NAME] [--workflow=FILE] [--release=TAG]
#                 [--apk-glob=PAT] [--log-glob=PAT]
#
# With --apk, after the merge the script keeps going: it waits for main's
# pipeline run for the merge commit (push event or automerge dispatch),
# waits for it to complete, then downloads the built APK artifact (falling
# back to the release tag) into out-dir (default ./apk-out) and MOVES the
# phone-facing APK(s) into the device Downloads folder (~/storage/downloads
# when writable, so "Move" — no second copy eating disk on a 66MB file).
#
# With --pr-apk, no merge is needed: downloads the artifact from the PR's
# own apk run immediately (fastest iteration feedback).
#
# With --latest-apk, after the merge the script waits for main's run on the
# merge commit, then downloads the republished release APK into dir
# (default ./apk-out).
#
# With --prune=dir, skips CI entirely and just prunes dir immediately
# (keeps only the newest APK_GLOB match plus the newest 2 LOG_GLOB matches,
# deleting the rest as stale). Pruning only ever touches those globs.
#
# Exit codes:
#   0  PR merged (+ artifacts downloaded if requested), or all checks pass
#   1  a check failed, the main run failed, or a download failed
#   2  PR cannot run CI at all (CONFLICTING: GitHub can't build the preview
#      merge ref, so no runs will ever trigger — merge main first)
#   3  PR closed unmerged / usage error / timed out waiting / missing config
set -uo pipefail

[ -d /data/data/com.termux/files/usr/bin ] && export PATH="$PATH:/data/data/com.termux/files/usr/bin"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export TMPDIR="${TMPDIR:-$HOME/.cache/babysit-tmp}"
mkdir -p "$TMPDIR"

# --- repo config: flags > .babysitrc > empty (fail loudly when needed) ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
APK_ARTIFACT=""; MAIN_WORKFLOW=""; RELEASE_TAG=""; APK_GLOB=""; LOG_GLOB=""
if [ -f "$REPO_ROOT/.babysitrc" ]; then
    # shellcheck disable=SC1090
    set -a; . "$REPO_ROOT/.babysitrc"; set +a
fi

PR=""
INTERVAL=60
MAX_POLLS=60
WANT_APK=0
APK_DIR="./apk-out"
WANT_PR_APK=0
PR_APK_DIR="./apk-out"
WANT_LATEST=0
LATEST_DIR="./apk-out"
WANT_PRUNE=0
PRUNE_DIR=""
PRUNE_AFTER_FETCH=1
for arg in "$@"; do
    case "$arg" in
        --apk) WANT_APK=1 ;;
        --apk=*) WANT_APK=1; APK_DIR="${arg#--apk=}" ;;
        --pr-apk) WANT_PR_APK=1 ;;
        --pr-apk=*) WANT_PR_APK=1; PR_APK_DIR="${arg#--pr-apk=}" ;;
        --latest-apk) WANT_LATEST=1 ;;
        --latest-apk=*) WANT_LATEST=1; LATEST_DIR="${arg#--latest-apk=}" ;;
        --prune=*) WANT_PRUNE=1; PRUNE_DIR="${arg#--prune=}" ;;
        --no-prune) PRUNE_AFTER_FETCH=0 ;;
        --artifact=*) APK_ARTIFACT="${arg#--artifact=}" ;;
        --workflow=*) MAIN_WORKFLOW="${arg#--workflow=}" ;;
        --release=*) RELEASE_TAG="${arg#--release=}" ;;
        --apk-glob=*) APK_GLOB="${arg#--apk-glob=}" ;;
        --log-glob=*) LOG_GLOB="${arg#--log-glob=}" ;;
        *) if [ -z "$PR" ]; then PR="$arg";
           elif [ "$INTERVAL" = "60" ]; then INTERVAL="$arg";
           elif [ "$MAX_POLLS" = "60" ]; then MAX_POLLS="$arg";
           else echo "usage: $0 <PR> [interval_sec] [max_polls] [options]" >&2; exit 3; fi ;;
    esac
done
if [ "$WANT_PRUNE" = "1" ]; then
    [ -n "$PRUNE_DIR" ] || { echo "usage: $0 --prune=dir" >&2; exit 3; }
    [ -d "$PRUNE_DIR" ] || { echo "babysit: not a directory: $PRUNE_DIR" >&2; exit 3; }
    PRUNE_ONLY=1
else
    PRUNE_ONLY=0
    [ -n "$PR" ] || { echo "usage: $0 <PR> [interval_sec] [max_polls] [options]" >&2; exit 3; }
fi
command -v gh >/dev/null || { echo "babysit: gh CLI not found" >&2; exit 3; }

need_cfg() { # $1=var name $2=flag to set it
    if [ -z "${!1}" ]; then
        echo "babysit: $1 is unset — add it to .babysitrc or pass $2." >&2
        exit 3
    fi
}

# Wait for a workflow run to complete. Prints final status, exits nonzero
# unless the run concluded successfully.
wait_for_run() {
    local run_id="$1" phase="$2" n=0 status="" concl=""
    while [ "$n" -lt "$MAX_POLLS" ]; do
        n=$((n + 1))
        status="$(gh run view "$run_id" --json status --jq .status 2>/dev/null || echo UNKNOWN)"
        concl="$(gh run view "$run_id" --json conclusion --jq .conclusion 2>/dev/null || echo "")"
        if [ "$status" = "completed" ]; then
            echo "babysit: $phase run $run_id completed: ${concl:-unknown}"
            [ "$concl" = "success" ] && return 0 || return 1
        fi
        echo "babysit: $phase run $run_id $status... [$n/$MAX_POLLS]"
        sleep "$INTERVAL"
    done
    echo "babysit: timed out waiting for $phase run $run_id." >&2
    return 3
}

# Move phone-facing APK(s) into device Downloads (Termux-visible path).
# Zero-old policy: after the move, Downloads is pruned to the newest
# APK_GLOB match (+ 2 logs) so no stale bundles linger next to the fresh one.
# Returns 0 with the final path(s) listed. "Move" — no second copy eating
# disk on a 60MB+ file. Skips with a loud note when Downloads is missing
# (plain Linux CI hosts) or unwritable.
move_to_downloads() {
    local dir="" downloads=""
    if [ -n "${1:-}" ]; then dir="$1"; else dir="./apk-out"; fi
    if [ -n "${DOWNLOADS_DIR:-}" ]; then
        downloads="$DOWNLOADS_DIR"
    elif [ -n "${HOME:-}" ] && [ -d "$HOME/storage/downloads" ]; then
        downloads="$HOME/storage/downloads"
    fi
    if [ -z "$downloads" ]; then
        echo "babysit: no device Downloads folder — left APKs in $dir."
        return 0
    fi
    if [ ! -d "$downloads" ] || [ ! -w "$downloads" ]; then
        echo "babysit: Downloads '$downloads' missing/unwritable — left APKs in $dir." >&2
        return 0
    fi
    need_cfg APK_GLOB "--apk-glob"
    local listed
    # shellcheck disable=SC2086
    listed="$(ls -t $dir/$APK_GLOB 2>/dev/null || true)"
    if [ -z "$listed" ]; then
        echo "babysit: nothing matching $APK_GLOB in $dir to move."
        return 0
    fi
    echo "$listed" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        if mv -f "$dir/$f" "$downloads/$f" 2>/dev/null; then
            echo "babysit: moved $f -> $downloads/"
        elif cp -f "$dir/$f" "$downloads/$f" 2>/dev/null; then
            # Cross-device rename (e.g. Termux storage symlink resolved to a
            # different mount by the kernel) — copy then unlink the source so
            # a 60MB+ APK is never held twice unless the move truly fails.
            rm -f "$dir/$f" 2>/dev/null || true
            echo "babysit: moved(copy+unlink) $f -> $downloads/"
        else
            echo "babysit: WARNING: could not move $f to $downloads/" >&2
        fi
    done
    prune_downloads "$downloads"
    echo "babysit: Downloads holds:"
    ls -lh "$downloads" | tail -5
    return 0
}

# Remove stale siblings in a download dir. APKs live loose, so scan the dir;
# keep only the newest APK_GLOB match and the newest 2 LOG_GLOB matches.
# Removal failures are reported loudly (never silently swallowed) but do not
# fail the run — the download is the deliverable.
prune_downloads() {
    local dir="$1" f="" i=0 failed=0
    need_cfg APK_GLOB "--apk-glob"
    need_cfg LOG_GLOB "--log-glob"
    local apks=()
    # shellcheck disable=SC2086
    while IFS= read -r f; do apks+=("$f"); done < <(ls -t $dir/$APK_GLOB 2>/dev/null || true)
    if [ "${#apks[@]}" -gt 0 ]; then
        for f in "${apks[@]:1}"; do
            echo "babysit: removing stale APK: $f"
            rm -f "$f" || { echo "babysit: WARNING: could not remove $f" >&2; failed=1; }
        done
    fi
    i=0
    # shellcheck disable=SC2086
    while IFS= read -r f; do
        i=$((i + 1))
        if [ "$i" -gt 2 ]; then
            echo "babysit: removing stale log: $f"
            rm -f "$f" || { echo "babysit: WARNING: could not remove $f" >&2; failed=1; }
        fi
    done < <(ls -t $dir/$LOG_GLOB 2>/dev/null || true)
    if [ "$failed" -ne 0 ]; then
        echo "babysit: WARNING: some stale files could not be removed (see above)." >&2
    fi
    return 0
}

# After the merge: find main's pipeline run for the merge commit, wait for
# it, and download the built APK.
fetch_merge_apk() {
    local pr="$1" n=0 sha="" run_id=""
    need_cfg MAIN_WORKFLOW "--workflow"
    need_cfg APK_ARTIFACT "--artifact"
    sha="$(gh pr view "$pr" --json mergeCommit --jq .mergeCommit.oid 2>/dev/null || echo "")"
    [ -n "$sha" ] || { echo "babysit: cannot resolve merge commit for PR #$pr." >&2; return 3; }
    echo "babysit: PR #$pr merged as $sha; waiting for main's pipeline..."
    while [ "$n" -lt "$MAX_POLLS" ]; do
        n=$((n + 1))
        run_id="$(gh run list --workflow="$MAIN_WORKFLOW" --branch main --limit 10 \
            --json databaseId,headSha,status \
            --jq "[.[] | select(.headSha == \"$sha\")] | .[0].databaseId // empty" 2>/dev/null || echo "")"
        [ -n "$run_id" ] && break
        echo "babysit: no main run for $sha yet... [$n/$MAX_POLLS]"
        sleep "$INTERVAL"
    done
    [ -n "$run_id" ] || { echo "babysit: no main pipeline run appeared for $sha." >&2; return 3; }
    echo "babysit: main run: $run_id"
    wait_for_run "$run_id" "main" || {
        echo "babysit: main run failed — APK not published." >&2
        return 1
    }
    mkdir -p "$APK_DIR"
    if gh run download "$run_id" -n "$APK_ARTIFACT" -D "$APK_DIR" 2>/dev/null; then
        echo "babysit: APK downloaded to $APK_DIR:"
        ls -lh "$APK_DIR"
        if [ "$PRUNE_AFTER_FETCH" = "1" ]; then
            prune_downloads "$APK_DIR"
        fi
        move_to_downloads "$APK_DIR"
        return 0
    fi
    need_cfg RELEASE_TAG "--release"
    echo "babysit: artifact gone (retention?); falling back to $RELEASE_TAG release..."
    gh release download "$RELEASE_TAG" --pattern '*.apk' --dir "$APK_DIR" --clobber || {
        echo "babysit: APK download failed from artifact and release." >&2
        return 1
    }
    ls -lh "$APK_DIR"/*.apk
    if [ "$PRUNE_AFTER_FETCH" = "1" ]; then
        prune_downloads "$APK_DIR"
    fi
    move_to_downloads "$APK_DIR"
    return 0
}

# No merge needed: download the APK artifact from the PR's own apk run.
fetch_pr_apk() {
    local pr="$1" run_id=""
    need_cfg APK_ARTIFACT "--artifact"
    run_id="$(gh pr checks "$pr" 2>/dev/null | grep -oP 'runs/\K[0-9]+' | head -1)"
    [ -n "$run_id" ] || { echo "babysit: no workflow run found for PR #$pr." >&2; return 3; }
    mkdir -p "$PR_APK_DIR"
    if gh run download "$run_id" -n "$APK_ARTIFACT" -D "$PR_APK_DIR" 2>&1 | tail -1; then
        echo "babysit: APK downloaded to $PR_APK_DIR:"
        ls -lh "$PR_APK_DIR"
        if [ "$PRUNE_AFTER_FETCH" = "1" ]; then
            prune_downloads "$PR_APK_DIR"
        fi
        move_to_downloads "$PR_APK_DIR"
        return 0
    fi
    echo "babysit: APK download failed for run $run_id." >&2
    return 3
}

# After the merge: wait for main's run on the merge commit, then download
# the republished release APK.
fetch_latest_apk() {
    local pr="$1" n=0 done=0 sha="" run_id="" status="" concl=""
    need_cfg MAIN_WORKFLOW "--workflow"
    need_cfg RELEASE_TAG "--release"
    sha="$(gh pr view "$pr" --json mergeCommit --jq .mergeCommit.oid 2>/dev/null || echo "")"
    [ -n "$sha" ] || { echo "babysit: PR #$pr has no merge commit yet." >&2; return 3; }
    echo "babysit: waiting for main run on merge commit $sha..."
    while [ "$n" -lt "$MAX_POLLS" ]; do
        n=$((n + 1))
        run_id="$(gh run list --workflow="$MAIN_WORKFLOW" --branch main --limit 10 \
            --json databaseId,headSha,status,conclusion \
            --jq "[.[] | select(.headSha==\"$sha\")] | .[0] | .databaseId // empty" 2>/dev/null || echo "")"
        if [ -z "$run_id" ]; then
            echo "babysit: main run for $sha not started yet... [$n/$MAX_POLLS]"
        else
            status="$(gh run view "$run_id" --json status --jq .status 2>/dev/null || echo UNKNOWN)"
            concl="$(gh run view "$run_id" --json conclusion --jq .conclusion 2>/dev/null || echo "")"
            if [ "$status" = "completed" ]; then
                if [ "$concl" = "success" ]; then
                    echo "babysit: main run $run_id succeeded."
                    done=1
                    break
                fi
                echo "babysit: main run $run_id concluded: ${concl:-unknown}." >&2
                return 1
            fi
            echo "babysit: main run $run_id $status... [$n/$MAX_POLLS]"
        fi
        sleep "$INTERVAL"
    done
    if [ "$done" != "1" ]; then
        echo "babysit: timed out waiting for main run on $sha." >&2
        return 3
    fi
    mkdir -p "$LATEST_DIR"
    gh release download "$RELEASE_TAG" --pattern '*.apk' --dir "$LATEST_DIR" --clobber >/dev/null \
        || { echo "babysit: latest-release APK download failed." >&2; return 3; }
    echo "babysit: latest APK downloaded to $LATEST_DIR:"
    ls -lh "$LATEST_DIR"
    prune_downloads "$LATEST_DIR"
    move_to_downloads "$LATEST_DIR"
}

if [ "$PRUNE_ONLY" = "0" ]; then
poll=0
EMPTY_CHECKS=0
while [ "$poll" -lt "$MAX_POLLS" ]; do
    poll=$((poll + 1))
    STATE="$(gh pr view "$PR" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    if [ "$STATE" = "MERGED" ]; then
        MERGED_AT="$(gh pr view "$PR" --json mergedAt --jq .mergedAt 2>/dev/null || echo unknown)"
        echo "babysit: PR #$PR is MERGED (at $MERGED_AT)."
        break
    fi
    if [ "$STATE" = "CLOSED" ]; then
        echo "babysit: PR #$PR is CLOSED unmerged." >&2
        exit 3
    fi
    MERGEABLE="$(gh pr view "$PR" --json mergeable --jq .mergeable 2>/dev/null || echo UNKNOWN)"
    if [ "$MERGEABLE" = "CONFLICTING" ]; then
        echo "babysit: PR #$PR is CONFLICTING — GitHub cannot build the preview merge ref," >&2
        echo "babysit: so NO CI will ever trigger. Merge main into the branch and push first." >&2
        exit 2
    fi
    CHECKS="$(gh pr checks "$PR" 2>&1)"
    if printf '%s\n' "$CHECKS" | grep -q "no checks reported"; then
        EMPTY_CHECKS=$((EMPTY_CHECKS + 1))
        echo "babysit: [$poll/$MAX_POLLS] no checks reported yet (trigger pending?)..."
        if [ "$EMPTY_CHECKS" -ge 5 ]; then
            echo "babysit: still no checks after $EMPTY_CHECKS polls — verify the push landed and paths filters match." >&2
            exit 3
        fi
        sleep "$INTERVAL"
        continue
    fi
    echo "babysit: [$poll/$MAX_POLLS] checks on PR #$PR:"
    printf '%s\n' "$CHECKS" | sed 's/^/babysit: /' | head -15
    if printf '%s\n' "$CHECKS" | awk '{print $2}' | grep -qx "fail"; then
        echo "babysit: FAILURES detected:" >&2
        printf '%s\n' "$CHECKS" | awk '$2 == "fail"' | sed 's/^/babysit: /' >&2
        echo "babysit: investigate with: gh run view <run-id> --log-failed" >&2
        exit 1
    fi
    if ! printf '%s\n' "$CHECKS" | awk '{print $2}' | grep -Eq "pending|queued|in_progress|waiting|requested"; then
        echo "babysit: all reported checks pass on PR #$PR."
        break
    fi
    echo "babysit: still running; sleeping ${INTERVAL}s..."
    sleep "$INTERVAL"
done
fi

# Post-check phases run even for already-merged PRs (loop above breaks on MERGED).
if [ "$WANT_APK" = "1" ]; then
    fetch_merge_apk "$PR"
    rc=$?
    [ "$rc" -ne 0 ] && exit "$rc"
fi

if [ "$WANT_PR_APK" = "1" ]; then
    fetch_pr_apk "$PR"
    rc=$?
    [ "$rc" -ne 0 ] && exit "$rc"
fi

if [ "$WANT_LATEST" = "1" ]; then
    fetch_latest_apk "$PR"
    rc=$?
    [ "$rc" -ne 0 ] && exit "$rc"
fi

if [ "$WANT_PRUNE" = "1" ]; then
    prune_downloads "$PRUNE_DIR"
fi

echo "babysit: Done."
exit 0
