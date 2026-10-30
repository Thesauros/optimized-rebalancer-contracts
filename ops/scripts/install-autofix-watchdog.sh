#!/usr/bin/env bash
set -euo pipefail
repo=/root/optimized-rebalancer-contracts
cd "$repo"
if [[ "$(id -u)" != 0 ]]; then
  echo 'Run as root' >&2
  exit 1
fi
if systemctl is-active --quiet xc-watchdog.service; then
  echo 'Watchdog is running; wait for it to finish before upgrading' >&2
  exit 1
fi
python3 -m unittest discover -s ops/test -p 'test_autofix_watchdog.py'
python3 - <<'PY'
from pathlib import Path
keys = {}
for line in Path('ops/.env.server').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        key, value = line.split('=', 1)
        if key in ('TELEGRAM_TOKEN', 'TELEGRAM_CHAT_ID'):
            keys[key] = value.strip().strip('"\'')
assert keys.get('TELEGRAM_TOKEN') and keys.get('TELEGRAM_CHAT_ID'), 'Existing Telegram bot must be configured'
PY
install -m 0755 ops/scripts/autofix-watchdog.py /usr/local/sbin/xc-autofix-watchdog
install -m 0644 ops/deploy/xc-watchdog.service /etc/systemd/system/xc-watchdog.service
systemd-analyze verify /etc/systemd/system/xc-watchdog.service
systemctl daemon-reload
# Install cron last, after the unit and script have passed validation.
install -m 0644 ops/deploy/xc-watchdog.cron /etc/cron.d/xc-watchdog
systemctl enable --now cron.service
systemctl start xc-watchdog.service
systemctl show xc-watchdog.service -p Result -p ExecMainStatus
