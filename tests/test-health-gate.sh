#!/usr/bin/env bash
# steellz fork: post-update health gate + auto-rollback (HEALTH_GATE in update.sh),
# exercised against fake pct/qm commands.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
FAKE="$WORK_DIR/fake"
BIN="$WORK_DIR/bin"
mkdir -p "$FAKE" "$BIN"
export FAKE

# Fake guest tools. $FAKE/state = running|stopped, $FAKE/probe = what the guest reports,
# $FAKE/probe.snapshot = what it reports after a rollback, $FAKE/calls = actions taken.
cat > "$BIN/pct" <<'EOF'
#!/bin/bash
case "$1" in
  status) echo "status: $(cat "$FAKE/state")" ;;
  exec) cat "$FAKE/probe" ;;
  stop) echo "stop $2" >> "$FAKE/calls"; echo stopped > "$FAKE/state" ;;
  rollback) echo "rollback $2 $3" >> "$FAKE/calls"
            if [[ -f "$FAKE/rollback-fails" ]]; then echo "rollback failed: lvm error" >&2; exit 1; fi
            cp "$FAKE/probe.snapshot" "$FAKE/probe" ;;
  start) echo "start $2" >> "$FAKE/calls"; echo running > "$FAKE/state" ;;
esac
EOF
cat > "$BIN/qm" <<'EOF'
#!/bin/bash
case "$1" in
  status) echo "status: $(cat "$FAKE/state")" ;;
  guest)
    if [[ "$2" == cmd ]]; then [[ ! -f "$FAKE/agent-down" ]]; exit; fi
    python3 -c 'import json, sys; print(json.dumps({"exitcode": 0, "exited": 1, "out-data": open(sys.argv[1]).read()}))' "$FAKE/probe" ;;
  stop) echo "stop $2" >> "$FAKE/calls"; echo stopped > "$FAKE/state" ;;
  rollback) echo "rollback $2 $3" >> "$FAKE/calls"; rm -f "$FAKE/agent-down"; cp "$FAKE/probe.snapshot" "$FAKE/probe" ;;
  start) echo "start $2" >> "$FAKE/calls"; echo running > "$FAKE/state" ;;
esac
EOF
chmod +x "$BIN/pct" "$BIN/qm"
export PATH="$BIN:$PATH"

eval "$(sed -n '/^HEALTH_PROBE_SCRIPT=/,/^# Script-only mode is enabled/p' "$ROOT_DIR/update.sh" | sed '$d')"
STATUS_MODEL_UPDATE_RESULT() { printf '%s|%s|%s|%s\n' "$@" >> "$FAKE/records"; }
HEALTH_CHECK_WAIT=0
HEALTH_POLL_INTERVAL=0
CL="" RD="" GN="" OR=""

# scenario KIND BEFORE AFTER [SNAPSHOT_PROBE] [SNAPSHOT_NAME]
scenario() {
  local kind="$1" before="$2" after="$3" restored="${4:-}" snapshot="${5-Update_20261004_030000}"
  rm -f "$FAKE"/{calls,records,rollback-fails,agent-down}
  : > "$FAKE/calls"; : > "$FAKE/records"
  echo running > "$FAKE/state"
  printf '%s' "$before" > "$FAKE/probe"
  printf '%s' "$restored" > "$FAKE/probe.snapshot"
  UPDATE_FAILURE=false
  HEALTH_BASELINE "$kind" 101
  UU_UPDATE_SNAPSHOT="$snapshot"   # CONTAINER_BACKUP/VM_BACKUP set this during the update
  printf '%s' "$after" > "$FAKE/probe"
}
gate() { GATE_OUT=$(HEALTH_GATE "$1" 101 2>&1) && GATE_RC=0 || GATE_RC=$?; }

AUTO_ROLLBACK=true
HEALTH_CHECK=true

# 1. Healthy update: nothing happens.
scenario lxc $'docker:web\n' $'docker:web\n'
gate lxc
[[ $GATE_RC -eq 0 && ! -s "$FAKE/calls" && ! -s "$FAKE/records" ]]
grep -Fq 'healthy after the update' <<<"$GATE_OUT"

# 2. New failed unit -> rolled back, healthy again, recorded as failed (75) with a message.
scenario lxc $'docker:web\n' $'docker:web\nfailed:nginx.service\n' $'docker:web\n'
gate lxc
[[ $GATE_RC -eq 1 ]]
grep -Fxq 'rollback 101 Update_20261004_030000' "$FAKE/calls"
grep -Fxq 'start 101' "$FAKE/calls"
grep -Fq '101|failed|75|Health check failed after the update: systemd unit nginx.service failed. Rolled back to Update_20261004_030000 and it is healthy again' "$FAKE/records"
# gate() runs in a subshell, so check UPDATE_FAILURE with a direct call on a fresh scenario.
scenario lxc 'docker:web' 'failed:nginx.service' 'docker:web'
HEALTH_GATE lxc 101 >/dev/null 2>&1 || true
[[ "$UPDATE_FAILURE" == true ]]

# 3. A unit that was already failing before the update doesn't count.
scenario lxc $'failed:old.service\n' $'failed:old.service\n'
gate lxc
[[ $GATE_RC -eq 0 && ! -s "$FAKE/calls" ]]

# 4. Docker container gone and no snapshot -> 76, nothing rolled back.
scenario lxc $'docker:a\ndocker:b\n' $'docker:a\n' '' ''
gate lxc
[[ $GATE_RC -eq 1 && ! -s "$FAKE/calls" ]]
grep -Fq '101|failed|76|Health check failed after the update: Docker container b is no longer running. There was no pre-update snapshot to roll back to' "$FAKE/records"

# 5. Rollback itself fails -> says so.
scenario lxc '' $'failed:x.service\n' ''
touch "$FAKE/rollback-fails"
gate lxc
grep -Fq 'Rolling back to Update_20261004_030000 FAILED: rollback failed: lvm error' "$FAKE/records"

# 6. AUTO_ROLLBACK off -> report only.
AUTO_ROLLBACK=false
scenario lxc '' $'failed:x.service\n' ''
gate lxc
[[ ! -s "$FAKE/calls" ]]
grep -Fq '|76|' "$FAKE/records"
grep -Fq 'AUTO_ROLLBACK is off' "$FAKE/records"
AUTO_ROLLBACK=true

# 7. Container stopped after the update.
scenario lxc '' '' ''
echo stopped > "$FAKE/state"
gate lxc
grep -Fq 'not running (stopped)' "$FAKE/records"

# 8. VM whose guest agent stops answering -> rolled back via qm.
scenario vm $'docker:app\n' $'docker:app\n' $'docker:app\n'
touch "$FAKE/agent-down"
gate vm
grep -Fxq 'rollback 101 Update_20261004_030000' "$FAKE/calls"
grep -Fq 'guest agent stopped answering. Rolled back to Update_20261004_030000 and it is healthy again' "$FAKE/records"

# 9. Still unhealthy after the rollback -> says so.
scenario lxc '' $'failed:x.service\n' $'failed:x.service\n'
gate lxc
grep -Fq 'Rolled back to Update_20261004_030000, but it is still unhealthy: systemd unit x.service failed' "$FAKE/records"

# 10. HEALTH_CHECK off, or a guest that couldn't be probed before -> no-op.
HEALTH_CHECK=false
scenario lxc '' $'failed:x.service\n' ''
gate lxc
[[ $GATE_RC -eq 0 && ! -s "$FAKE/records" ]]
HEALTH_CHECK=true
scenario vm '' '' ''
touch "$FAKE/agent-down"; HEALTH_BASELINE vm 101; rm -f "$FAKE/agent-down"
printf 'failed:x.service\n' > "$FAKE/probe"
gate vm
[[ $GATE_RC -eq 0 && ! -s "$FAKE/records" ]]
grep -Fq "Health check skipped" <<<"$GATE_OUT"

# Hooks: both running-guest branches take a baseline before and gate after the update.
grep -Fq 'HEALTH_BASELINE lxc "$CONTAINER"' "$ROOT_DIR/update.sh"
grep -Fq 'HEALTH_GATE lxc "$CONTAINER" || true' "$ROOT_DIR/update.sh"
grep -Fq 'HEALTH_BASELINE vm "$VM"' "$ROOT_DIR/update.sh"
grep -Fq 'HEALTH_GATE vm "$VM" || true' "$ROOT_DIR/update.sh"
[[ $(grep -c 'UU_UPDATE_SNAPSHOT="Update_' "$ROOT_DIR/update.sh") -eq 2 ]]
for f in update.conf update.conf.dist; do
  grep -Fqx 'HEALTH_CHECK="true"' "$ROOT_DIR/$f"
  grep -Fqx 'AUTO_ROLLBACK="true"' "$ROOT_DIR/$f"
  grep -Fqx 'HEALTH_CHECK_WAIT="120"' "$ROOT_DIR/$f"
done

echo 'health gate tests: PASS'
