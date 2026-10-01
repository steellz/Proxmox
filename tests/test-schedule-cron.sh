#!/usr/bin/env bash
# steellz fork: `ultimate-updater schedule` turns SCHEDULED_CHECK / SCHEDULED_UPDATE in
# update.conf into a cron.d file, and never writes a malformed cron line.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

config="$WORK_DIR/update.conf"
cron="$WORK_DIR/ultimate-updater-schedule"
crontab="$WORK_DIR/crontab"
: > "$crontab"
run() { UU_LOCAL_FILES="$WORK_DIR" UU_CONFIG_FILE="$config" UU_SCHEDULE_CRON_FILE="$cron" UU_SYSTEM_CRONTAB="$crontab" bash "$ROOT_DIR/ultimate-updater" schedule "$@"; }

# Both templates ship the keys, empty (off).
grep -Fqx 'SCHEDULED_CHECK=""' "$ROOT_DIR/update.conf.dist"
grep -Fqx 'SCHEDULED_UPDATE=""' "$ROOT_DIR/update.conf.dist"
grep -Fqx 'SCHEDULED_CHECK=""' "$ROOT_DIR/update.conf"
grep -Fqx 'SCHEDULED_UPDATE=""' "$ROOT_DIR/update.conf"

# Off by default: nothing installed, and show says so.
printf 'SCHEDULED_CHECK=""\nSCHEDULED_UPDATE=""\n' > "$config"
out=$(run apply); grep -Fq 'No scheduled jobs' <<<"$out"
[[ ! -e "$cron" ]]
out=$(run show); grep -Fq 'No scheduled jobs installed' <<<"$out"

# Check only.
printf 'SCHEDULED_CHECK="0 5 * * *"\nSCHEDULED_UPDATE=""\n' > "$config"
run apply >/dev/null
grep -Fqx '0 5 * * * root RUN_FROM_CRON=true UU_JOB_SOURCE=scheduler /usr/local/sbin/ultimate-updater check >/dev/null 2>&1' "$cron"
if grep -Fq 'update-all' "$cron"; then exit 1; fi
[[ "$(stat -c '%a' "$cron")" == 644 ]]

# Both, and re-applying replaces rather than appends.
printf 'SCHEDULED_CHECK="0 5 * * *"\nSCHEDULED_UPDATE="0 3 * * 0"\n' > "$config"
run apply >/dev/null
run apply >/dev/null
grep -Fqx '0 3 * * 0 root RUN_FROM_CRON=true UU_JOB_SOURCE=scheduler /usr/local/sbin/ultimate-updater update-all >/dev/null 2>&1' "$cron"
[[ $(grep -c 'ultimate-updater check' "$cron") -eq 1 ]]
[[ $(grep -c 'ultimate-updater update-all' "$cron") -eq 1 ]]
[[ $(run show | wc -l) -eq 2 ]]

# A typo is reported and treated as off; the valid job is kept.
printf 'SCHEDULED_CHECK="0 5 * * *"\nSCHEDULED_UPDATE="sunday 3am"\n' > "$config"
err=$(run apply 2>&1 >/dev/null)
grep -Fq 'Ignoring invalid SCHEDULED_UPDATE="sunday 3am"' <<<"$err"
grep -Fq 'ultimate-updater check' "$cron"
if grep -Fq 'update-all' "$cron"; then exit 1; fi

# Clearing both removes the file again.
printf 'SCHEDULED_CHECK=""\nSCHEDULED_UPDATE=""\n' > "$config"
run apply >/dev/null
[[ ! -e "$cron" ]]

# Unknown subcommand is rejected.
if run bogus >/dev/null 2>&1; then exit 1; fi

# Upstream's per-node daily check is removed from /etc/crontab (SCHEDULED_CHECK replaces
# it); unrelated lines stay, a backup is kept, and a second run changes nothing.
cat > "$crontab" <<'EOF'
SHELL=/bin/sh
17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
00 06 * * * root RUN_FROM_CRON=true UU_JOB_SOURCE=scheduler /usr/local/sbin/update -check >/dev/null 2>&1
00 07,19 * * *  root    RUN_FROM_CRON=true UU_JOB_SOURCE=scheduler /etc/ultimate-updater/check-updates.sh
12 03 * * * root /opt/vendor/check-updates.sh
EOF
printf 'SCHEDULED_CHECK="0 5 * * *"\nSCHEDULED_UPDATE=""\n' > "$config"
out=$(run apply); grep -Fq "Removed upstream's per-node daily check" <<<"$out"
if grep -Eq 'update -check|/etc/ultimate-updater/check-updates' "$crontab"; then exit 1; fi
grep -Fq 'run-parts --report /etc/cron.hourly' "$crontab"
grep -Fq '/opt/vendor/check-updates.sh' "$crontab"
grep -Fq '/usr/local/sbin/update -check' "$WORK_DIR"/crontab.bak.*
before=$(sha256sum "$crontab")
run apply >/dev/null
[[ "$(sha256sum "$crontab")" == "$before" ]]
[[ $(ls "$WORK_DIR"/crontab.bak.* | wc -l) -eq 1 ]]

# The installer applies the schedule on install, update and Welcome-Screen install, and
# never re-adds upstream's per-node check cron.
[[ $(grep -c 'ultimate-updater" schedule apply' "$ROOT_DIR/install.sh") -eq 3 ]]
if grep -nE '^[[:space:]]*ensure_scheduled_check_cron[[:space:]]' "$ROOT_DIR/install.sh"; then exit 1; fi

echo 'schedule cron tests: PASS'
