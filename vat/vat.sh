#!/usr/bin/env bash
# volta-tools / vat
#
# Under Alpenglow the vote account pays VAT every epoch, while block revenue
# lands on the identity. vat moves SOL between them once an hour:
#
#   identity -> vote account    when the vote account holds less than
#                               VAT_LOW_EPOCHS of VAT, fill it up to VAT_RESERVE_EPOCHS
#   identity -> payout wallet   everything above VAT_IDENTITY_MIN
#
# It acts only on the node that votes with the real identity right now,
# so the same timer can run on both nodes of a failover pair.
# It signs with the identity keypair only. The withdrawer stays off the server.
#
# No warranty: you run it at your own risk. See README.md (Disclaimer) and LICENSE.

set -euo pipefail
export LC_ALL=C

SELF_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
. "$SELF_DIR/../lib/common.sh"
VAT_VERSION=$(volta_version "$SELF_DIR")

TX_FEE=5000   # lamports, one signature

usage(){
  cat <<EOF
vat $VAT_VERSION (volta-tools)
Keeps the vote account funded for Alpenglow VAT and sends spare SOL
from the identity to your payout wallet.

usage: vat.sh [--dry-run] [--version] [--help]
  --dry-run   only log what would be sent (same as VAT_DRY_RUN=1)

config: $ENV_FILE
No warranty: you run it at your own risk (README.md, Disclaimer).
EOF
}

force_dry=0
for a in "$@"; do
  case "$a" in
    --dry-run) force_dry=1 ;;
    --version) echo "vat $VAT_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

load_env
RPC_URL=${RPC_URL:-http://127.0.0.1:8899}
VAT_PER_EPOCH=${VAT_PER_EPOCH:-0.83}
VAT_LOW_EPOCHS=${VAT_LOW_EPOCHS:-3}
VAT_RESERVE_EPOCHS=${VAT_RESERVE_EPOCHS:-5}
VAT_RENT=${VAT_RENT:-0.03}
VAT_IDENTITY_MIN=${VAT_IDENTITY_MIN:-3}
VAT_IDENTITY_FLOOR=${VAT_IDENTITY_FLOOR:-1}
VAT_MIN_SWEEP=${VAT_MIN_SWEEP:-1}
VAT_TG=${VAT_TG:-1}
VAT_DRY_RUN=${VAT_DRY_RUN:-1}
[ "$force_dry" = 1 ] && VAT_DRY_RUN=1

# Telegram: every transfer as it happens; a problem once, until it changes or is gone.
notify(){ if [ "$VAT_TG" = 1 ]; then tg_send "vat on $HOST: $1" || true; fi; }
on_die(){ if [ "$VAT_TG" = 1 ]; then alert vat "ERROR: $1"; fi; }

for v in VAT_PER_EPOCH VAT_LOW_EPOCHS VAT_RESERVE_EPOCHS VAT_RENT VAT_IDENTITY_MIN VAT_IDENTITY_FLOOR VAT_MIN_SWEEP; do
  [[ ${!v} =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$v must be a number, got '${!v}'"
done
[[ $VAT_DRY_RUN =~ ^[01]$ ]] || die "VAT_DRY_RUN must be 0 or 1"
[[ $VAT_TG =~ ^[01]$ ]] || die "VAT_TG must be 0 or 1"

# One run at a time.
lock=/run/volta-vat.lock
[ -w /run ] || lock=${TMPDIR:-/tmp}/volta-vat.$(id -u).lock
exec 9>"$lock"
flock -n 9 || { log "another vat run is still going, exit"; exit 0; }

resolve_bins
# VAT_PAYOUT_WALLET or, if it is empty, another module's payout wallet (with a warning)
payout_for VAT \
  || die "no payout wallet: enter VAT_PAYOUT_WALLET in $ENV_FILE (or run install.sh). vat never runs without an explicit payout wallet"
[ "$PAYOUT_FROM" = VAT_PAYOUT_WALLET ] || log "WARN: VAT_PAYOUT_WALLET is empty, so vat pays out to $PAYOUT_FROM ($PAYOUT)"

# ---- what the validator runs with ----
detect_vote
detect_node
detect_identity
p=$(payout_problem "$PAYOUT")
[ -z "$p" ] || die "$PAYOUT_FROM $PAYOUT: $p"
detect_ledger
resolve_agave

# ---- act only on the node that is voting right now ----
active=$(active_identity)
if [ "$active" != "$ID" ]; then
  log "not the voting node (running as ${active:-<validator not answering>}), skip"
  exit 0
fi

# ---- balances and limits, all in lamports ----
bal(){ "$SOLANA" balance "$1" -u "$RPC_URL" --lamports 2>/dev/null | awk '{print $1}'; }
vat_for(){ awk -v r="$VAT_RENT" -v v="$VAT_PER_EPOCH" -v e="$1" 'BEGIN{printf "%d", (r+v*e)*1e9+0.5}'; }

idb=$(bal "$ID") || true
vb=$(bal "$VOTE") || true
if ! is_uint "$idb" || ! is_uint "$vb"; then die "cannot read balances via $(url_show "$RPC_URL")"; fi

target=$(vat_for "$VAT_RESERVE_EPOCHS")
low=$(vat_for "$VAT_LOW_EPOCHS")
id_min=$(lamports "$VAT_IDENTITY_MIN")
id_floor=$(lamports "$VAT_IDENTITY_FLOOR")
min_sweep=$(lamports "$VAT_MIN_SWEEP")
(( low <= target )) || die "VAT_LOW_EPOCHS is above VAT_RESERVE_EPOCHS"
(( id_floor <= id_min )) || die "VAT_IDENTITY_FLOOR is above VAT_IDENTITY_MIN"

log "vat $VAT_VERSION dry=$VAT_DRY_RUN | identity ${ID:0:6} $(sol "$idb") (keeps $VAT_IDENTITY_MIN) | vote ${VOTE:0:6} $(sol "$vb") (top-up below $(sol "$low") to $(sol "$target")) | payout ${PAYOUT:0:6}"

send(){ # send <lamports> <to> <what>
  local amount out
  amount=$(sol "$1")
  if [ "$VAT_DRY_RUN" = 1 ]; then
    log "DRY: would send $amount SOL to $2"
    return 0
  fi
  log "sending $amount SOL to $2"
  out=$("$SOLANA" transfer -k "$ID_KEY" "$2" "$amount" -u "$RPC_URL" --allow-unfunded-recipient 2>&1) \
    || die "$3 of $amount SOL failed: $(tail -1 <<< "$out")"
  log "$(grep -m1 -i signature <<< "$out" || tail -1 <<< "$out")"
  notify "$3: $amount SOL to ${2:0:6}..."
}

problem=""

# ---- 1. vote account top-up ----
if (( vb < low )); then
  need=$(( target - vb ))
  can=$(( idb - id_floor - TX_FEE ))
  if (( can < need )); then
    log "WARN: identity can give $(sol $(( can > 0 ? can : 0 ))) of the $(sol "$need") needed"
    problem="WARN: the identity is too low to fill the vote account"
  fi
  amt=$(( need < can ? need : can ))
  if (( amt > 0 )); then
    log "vote top-up: $(sol "$amt")"
    send "$amt" "$VOTE" "vote top-up"
    idb=$(( idb - amt - TX_FEE ))
  fi
fi

# ---- 2. sweep the rest of the identity ----
spare=$(( idb - id_min - TX_FEE ))
if (( spare >= min_sweep )); then
  log "sweep to payout: $(sol "$spare")"
  send "$spare" "$PAYOUT" "sweep to payout"
else
  if (( spare < 0 )); then spare=0; fi
  log "spare $(sol "$spare") is below VAT_MIN_SWEEP $VAT_MIN_SWEEP, nothing to sweep"
fi

# ---- Telegram: a new problem once, or that the old one is gone ----
if [ "$VAT_TG" = 1 ]; then
  if [ -n "$problem" ]; then alert vat "$problem"; else alert_clear vat; fi
fi
