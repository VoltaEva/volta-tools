#!/usr/bin/env bash
# volta-tools / vat installer
# Creates or OVERWRITES /etc/systemd/system/volta-vat.service and volta-vat.timer.
# Starts nothing: enable the timer yourself once the dry run looks right.

set -euo pipefail
export LC_ALL=C

SELF_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
. "$SELF_DIR/../lib/common.sh"

[ "$(id -u)" = 0 ] || die "run as root, it writes to /etc/systemd/system"
load_env

minute=${VAT_TIMER_MINUTE:-}
if [ -z "$minute" ]; then
  minute=$(( RANDOM % 60 ))
  log "VAT_TIMER_MINUTE is empty, picked a random one: $minute"
fi
if ! [[ $minute =~ ^[0-9]{1,2}$ ]] || (( 10#$minute > 59 )); then
  die "VAT_TIMER_MINUTE must be 0..59, got '$minute'"
fi
minute=$(printf %02d $(( 10#$minute )))
jitter=${VAT_TIMER_JITTER:-15min}
[[ $jitter =~ ^[0-9]+(s|sec|m|min|h)?$ ]] || die "VAT_TIMER_JITTER looks wrong: '$jitter' (examples: 900, 15min)"

# Same environment systemd will give the service, so the dry run tells the truth.
log "dry run, the way the timer will run it:"
env -i HOME="$HOME" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  VOLTA_ENV="$ENV_FILE" "$SELF_DIR/vat.sh" --dry-run || die "dry run failed, fix the config first"

unit=/etc/systemd/system/volta-vat
confirm "write $unit.service and $unit.timer (every hour at :$minute, plus up to $jitter)?" \
  || { log "nothing written"; exit 0; }

cat > "$unit.service" <<EOF
[Unit]
Description=volta-tools vat: VAT top-up for the vote account, identity sweep
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=VOLTA_ENV=$ENV_FILE
ExecStart=$SELF_DIR/vat.sh
EOF

cat > "$unit.timer" <<EOF
[Unit]
Description=volta-tools vat, hourly

[Timer]
OnCalendar=*-*-* *:$minute:00
RandomizedDelaySec=$jitter
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
log "volta-vat.service and volta-vat.timer written"
[ -z "${VOLTA_FROM_INSTALLER:-}" ] || exit 0
echo "next:"
echo "  systemctl enable --now volta-vat.timer   # start the hourly runs"
echo "  journalctl -u volta-vat -o cat           # what it did"
echo "  systemctl list-timers volta-vat.timer    # when it runs next"
if [ "${VAT_DRY_RUN:-1}" = 1 ]; then
  echo "  VAT_DRY_RUN=1: the timer only logs. Set VAT_DRY_RUN=0 when the log looks right."
fi
