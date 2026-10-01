#!/usr/bin/env bash
# steellz fork: `ultimate-updater schedule` turns SCHEDULED_CHECK / SCHEDULED_UPDATE in
# update.conf into a cron.d file, and never writes a malformed cron line.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

config="$WORK_DIR/update.conf"
cron="$WORK_DIR/ultimate-updater-schedule"
run() { UU_LOCAL_FILES="$WORK_DIR" UU_CONFIG_FILE="$config" UU_SCHEDULE_CRON_FILE="$cron" bash "$ROOT_DIR/ultimate-updater" schedule "$@"; }

# Both templates ship the keys, empty (off).
grep -Fqx 'SCHEDULED_CHECK=""' "$ROOT_DIR/update.conf.dist"
grep -Fqx 'SCHEDULED_UPDATE=""' "$ROOT_DIR/update.conf.dist"
grep -Fqx 'SCHEDULED_CHECK=""' "$ROOT_DIR/update.conf"
grep -Fqx 'SCHEDULED_UPDATE=""' "$ROOT_DIR/update.conf"

# Off by default: nothing installed, and show says so.
printf 'SCHEDULED_CHECK=""\nSCHEDULED_UPDATE=""\n' > "$config"
run apply | grep -Fq 'No scheduled jobs'
[[ ! -e "$cron" ]]
run show | grep -Fq 'No scheduled jobs installed'

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

# The installer applies the schedule on both the install and the update path.
[[ $(grep -c 'ultimate-updater" schedule apply' "$ROOT_DIR/install.sh") -eq 2 ]]

echo 'schedule cron tests: PASS'
