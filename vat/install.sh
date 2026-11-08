#!/usr/bin/env bash
# volta-tools / vat installer
# Creates or OVERWRITES /etc/systemd/system/volta-vat.service and volta-vat.timer.
# Starts nothing: enable the timer yourself once the dry run looks right.
# No warranty: you run it at your own risk. See README.md (Disclaimer) and LICENSE.

set -euo pipefail
export LC_ALL=C

SELF_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck disable=SC2034  # read by die() in lib/common.sh
VOLTA_UI=1
# shellcheck source=../lib/common.sh
. "$SELF_DIR/../lib/common.sh"
trap 'printf "%s" "$C_0" >&2' EXIT
# run by install.sh, which tells about a Ctrl+C itself
[ -n "${VOLTA_FROM_INSTALLER:-}" ] || trap 'echo; err "stopped (Ctrl+C)"; exit 130' INT

[ "$(id -u)" = 0 ] || die "run as root, it writes to /etc/systemd/system"
case "$ENV_FILE" in /*) ;; *) ENV_FILE=$PWD/$ENV_FILE ;; esac
# the units take these paths as they are
for p in "$SELF_DIR" "$ENV_FILE"; do
  [[ $p =~ ^/[A-Za-z0-9._/@+-]*$ ]] \
    || die "the path \"$p\" has a space or another unusual character: systemd can't use it. Put volta-tools (and VOLTA_ENV) under a plain path, like /root/volta-tools"
done
load_env

minute=${VAT_TIMER_MINUTE:-}
if [ -z "$minute" ]; then
  minute=$(( RANDOM % 60 ))
  say "VAT_TIMER_MINUTE is empty, picked a random one: $minute"
fi
if ! [[ $minute =~ ^[0-9]{1,2}$ ]] || (( 10#$minute > 59 )); then
  die "VAT_TIMER_MINUTE must be 0..59, got '$minute'"
fi
minute=$(printf %02d $(( 10#$minute )))
jitter=${VAT_TIMER_JITTER:-15min}
[[ $jitter =~ ^[0-9]+(s|sec|m|min|h)?$ ]] || die "VAT_TIMER_JITTER looks wrong: '$jitter' (examples: 900, 15min)"

# Same environment systemd will give the service, so the dry run tells the truth.
say "A dry run, the way the timer will run it:"
env -i HOME="$HOME" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  VOLTA_ENV="$ENV_FILE" "$SELF_DIR/vat.sh" --dry-run 2>&1 | sed 's/^/    /' || die "dry run failed, fix the config first"

unit=/etc/systemd/system/volta-vat
was=$(timer_state vat)
say "The timer:"
say "  $unit.service"
say "  $unit.timer"
say "  every hour at :$minute, plus a random delay of up to $jitter"
case "$was" in
  on)  say "  installed and on now: updated, it stays on, with the schedule above"; q="Update the vat timer?" ;;
  off) say "  installed now, not on: updating it does not start it"; q="Update the vat timer?" ;;
  *)   say "  installed, not started"; q="Install the vat timer?" ;;
esac
if ! confirm "  $q"; then
  if [ "$was" = none ]; then say "Skipped: the vat timer is not installed. The config is saved."
  else say "Skipped: the vat timer stays as it was. The config is saved."; fi
  [ -z "${VOLTA_FROM_INSTALLER:-}" ] || exit 3     # install.sh: you said no
  exit 0
fi

cat > "$unit.service" <<UNIT
[Unit]
Description=volta-tools vat: VAT top-up for the vote account, identity sweep
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=VOLTA_ENV=$ENV_FILE
ExecStart=$SELF_DIR/vat.sh
UNIT

cat > "$unit.timer" <<UNIT
[Unit]
Description=volta-tools vat, hourly

[Timer]
OnCalendar=*-*-* *:$minute:00
RandomizedDelaySec=$jitter
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
if [ "$was" = on ]; then ok "the vat timer is updated, and it is on"; else ok "the vat timer is installed, not started"; fi
[ -z "${VOLTA_FROM_INSTALLER:-}" ] || exit 0
say "Next:"
[ "$was" = on ] || printf '    %-46s # %s\n' "systemctl enable --now volta-vat.timer" "start the hourly runs"
printf '    %-46s # %s\n' "journalctl -u volta-vat -o cat" "what it did" "systemctl list-timers volta-vat.timer" "when it runs next"
if [ "${VAT_DRY_RUN:-1}" = 1 ]; then
  say "VAT_DRY_RUN=1: the timer only logs. Set VAT_DRY_RUN=0 when the log looks right."
fi
