# pr-babysitter

One PR-babysitting script for every repo. Polls checks to green, fetches
APKs, prunes download dirs. No forks, no drift: repo-specific values live
in each consumer's `.babysitrc`, never in the script.

## Install (pinned)

```bash
curl -fsSL https://raw.githubusercontent.com/1337farm/pr-babysitter/v1/babysit-pr.sh -o ~/bin/babysit-pr.sh
chmod +x ~/bin/babysit-pr.sh
```

Requires the [GitHub CLI](https://cli.github.com/) (`gh`) authenticated.

## Per-repo setup

Copy `.babysitrc.example` to `.babysitrc` at the repo root and fill in:

| Key | Meaning | Example |
|-----|---------|---------|
| `APK_ARTIFACT` | artifact name holding the APK | `FlashForgeFarm-Debug-APK` |
| `MAIN_WORKFLOW` | pipeline workflow file on main | `native-engine-build.yml` |
| `RELEASE_TAG` | rolling release tag for fallback | `farm-apk-latest` |
| `APK_GLOB` | prune pattern for APKs | `FlashForgeFarm_*.apk` |
| `LOG_GLOB` | prune pattern for logs | `*.log` |

CLI flags (`--artifact=… --workflow=… --release=… --apk-glob=… --log-glob=…`)
override the file for one-offs.

## Usage

```bash
babysit-pr.sh <PR> [interval_sec=60] [max_polls=60] [--apk[=dir]] [--latest-apk[=dir]] [--pr-apk[=dir]] [--prune=dir] [--no-prune]
```

- No flags: poll checks until green/merged.
- `--pr-apk`: download the PR's own APK artifact now (fastest feedback).
- `--apk`: after merge, wait for main's run on the merge commit, download.
- `--latest-apk`: after merge, wait for main, download the release APK.
- `--prune=dir`: keep newest APK + newest 2 logs, delete the rest.

## Exit codes

- `0` green/merged (+ artifacts if requested)
- `1` check/run/download failure
- `2` CONFLICTING — merge main first, CI can never trigger
- `3` closed/timed out/usage/missing config

## Versioning

Tag releases `v1`, `v2`, … Consumers pin the install URL. Breaking flag
changes bump the major; new optional flags don't.
