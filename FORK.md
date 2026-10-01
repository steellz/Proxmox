# steellz fork of Ultimate Updater

This is a modified copy of [BassT23/Proxmox](https://github.com/BassT23/Proxmox)
(Ultimate Updater) for one homelab's Proxmox cluster. All credit for the
updater belongs to BassT23 and its contributors. Like the original, this fork
is licensed under the [GNU GPL v3](LICENSE). Report bugs in the updater itself
upstream, not here.

## What this fork changes

GPLv3 §5(a) requires modified versions to say what changed and when. These are
all the changes from upstream:

**2026-10-01**, based on upstream 5.1.3 (`fddc551`):

- **It updates itself from this fork.** `UU_REPO` in `product-metadata.sh`
  (default `steellz/Proxmox`) is now the one place that sets where the
  installer, self-update (`update -up`), version checks and component
  downloads come from (`install.sh`, `update.sh`, `tag-filter.sh`).
  Previously those pointed at upstream, so a self-update would have replaced
  the fork with upstream's code. GitHub doesn't copy releases into forks, so
  `master` now installs from the branch archive when there is no release.
  Informational links (issues, docs, credits) still point upstream.
- **New scheduled jobs: `SCHEDULED_CHECK` and `SCHEDULED_UPDATE`.** These
  two settings in `update.conf` take a 5-field cron schedule; empty means off.
  `ultimate-updater schedule apply` (also run by the installer) turns them
  into `/etc/cron.d/ultimate-updater-schedule`, which runs
  `ultimate-updater check` / `update-all` headless. Both run cluster-wide, so
  set them on **one** node only. An invalid schedule is reported and ignored,
  never written as a broken cron line. `ultimate-updater schedule show` lists
  what's installed. In the Web UI the keys are `internal`: kept on save, but
  not shown.
- **Upstream's per-node daily check is removed.** Upstream's Welcome-Screen
  option adds `update -check` / `check-updates.sh` to each node's
  `/etc/crontab`, which would overlap with `SCHEDULED_CHECK`. `schedule
  apply` removes those lines, keeping a timestamped `/etc/crontab.bak.*`, and
  the installer no longer calls `ensure_scheduled_check_cron`. The function
  itself is kept for upstream's test.
- **Health check + auto-rollback after each guest update.** A running LXC or VM
  is probed just before its update and again afterwards. It must still be
  running, have no *new* failed systemd units (units failing before the update
  don't count), every Docker container that was running must be running again,
  and a VM's guest agent must still answer. Services get `HEALTH_CHECK_WAIT`
  seconds (default 120) to settle. If the guest isn't healthy by then and
  `AUTO_ROLLBACK="true"`, it is stopped, rolled back to the `Update_*`
  snapshot taken just before the update, started and re-checked. The update is
  recorded as `failed`, with exit code 75 for "rolled back" or 76 for "nothing
  to roll back to", and a plain-language `last_update.message` in
  `status.json` (`STATUS_MODEL_UPDATE_RESULT` has an optional 4th argument
  for it). Settings: `HEALTH_CHECK`, `AUTO_ROLLBACK` and `HEALTH_CHECK_WAIT`
  (Web UI category `internal`). Hosts are not gated: they have no snapshot to
  roll back to. The code is the `HEALTH_*` block in `update.sh`, hooked into
  the running-guest branches of `CONTAINER_UPDATE_START` / `VM_UPDATE_START`.
  Verified end-to-end on a throwaway container: a newly failing service was
  rolled back and the container was healthy again.
- **Tests:** new `tests/test-schedule-cron.sh` and `tests/test-health-gate.sh`, and
  `tests/test-branch-selection.sh` now fails if any functional download URL
  points back at upstream.

## Installing or switching a node to this fork

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/steellz/Proxmox/master/install.sh) update
```

On a node that already has upstream installed, `update` replaces the program
files and keeps `update.conf`; new keys are merged in, empty. Use `install`
on a fresh node. After that, `update -up` keeps updating from this fork.

## Pulling in upstream fixes

```bash
git fetch upstream
git merge upstream/master        # conflicts are most likely in install.sh / update.sh URLs
bash tests/test-branch-selection.sh && bash tests/test-schedule-cron.sh
git push origin master
```

Keep every functional URL on `$UU_REPO`; the branch-selection test checks this.
Then run `update -up` on each node. It compares commits, not version numbers,
so a merge installs even when upstream hasn't bumped its version.
