#!/usr/bin/env bash
# volta-tools installer
#
# Finds what your validator runs with, asks only what it can't find (payout wallet,
# Telegram), writes one config for all modules and installs the modules you pick.
# Run it again any time: current values are the defaults, changes are shown first.
# Writes the config (.env next to this file) and /etc/systemd/system/volta-*.
# Starts nothing.

set -euo pipefail
export LC_ALL=C

VOLTA_HOME=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
export VOLTA_HOME
# shellcheck source=lib/common.sh
. "$VOLTA_HOME/lib/common.sh"

[ "$(id -u)" = 0 ] || die "run as root: it reads the validator keys and writes systemd units"
for c in curl flock awk diff systemctl; do
  command -v "$c" >/dev/null || die "$c is missing"
done

declare -A CFG SEEN

# ---- checks for the answers ----
check_unit(){
  systemctl cat "${1%.service}.service" >/dev/null 2>&1 && return 0
  echo "  no such unit" >&2; return 1
}
check_bindir(){
  [ -x "$1/solana" ] && [ -x "$1/solana-keygen" ] && return 0
  echo "  no solana and solana-keygen there" >&2; return 1
}
check_rpc(){
  "$SOLANA" -u "$1" epoch-info >/dev/null 2>&1 && return 0
  echo "  no answer from $1" >&2; return 1
}
check_vote(){
  if is_pubkey "$1" && "$SOLANA" vote-account "$1" -u "$RPC_URL" >/dev/null 2>&1; then return 0; fi
  echo "  not a vote account" >&2; return 1
}
check_idkey(){
  if [ -f "$1" ] && [ "$("$KEYGEN" pubkey "$1" 2>/dev/null || true)" = "$NODE" ]; then return 0; fi
  echo "  not the keypair of $NODE" >&2; return 1
}
check_dir(){
  [ -d "$1" ] && return 0
  echo "  no such folder" >&2; return 1
}
check_exec(){
  [ -x "$1" ] && return 0
  echo "  not an executable file" >&2; return 1
}
check_token(){
  if [ -z "$1" ] || [[ $1 =~ ^[0-9]{5,12}:[A-Za-z0-9_-]{30,}$ ]]; then return 0; fi
  echo "  that does not look like a bot token (123456789:AA...)" >&2; return 1
}
check_chat(){
  if [[ $1 =~ ^-?[0-9]+$ || $1 =~ ^@[A-Za-z0-9_]{5,}$ ]]; then return 0; fi
  echo "  a number like -1001234567890, or @channelname" >&2; return 1
}
# Does a detection step work without asking? (runs it in a subshell, quietly)
try(){ ( "$@" ) >/dev/null 2>&1; }

# ---- 1. the current config gives the defaults ----
if [ -f "$ENV_FILE" ]; then
  log "config $ENV_FILE found, its values are the defaults"
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    v=${BASH_REMATCH[2]}
    v=${v%%[[:space:]]#*}
    v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
    CFG[${BASH_REMATCH[1]}]=$v
  done < <(tr -d '\r' < "$ENV_FILE")
fi
VALIDATOR_UNIT=${CFG[VALIDATOR_UNIT]:-}
SOLANA_BIN_DIR=${CFG[SOLANA_BIN_DIR]:-}
VALIDATOR_BIN=${CFG[VALIDATOR_BIN]:-}
IDENTITY_KEYPAIR=${CFG[IDENTITY_KEYPAIR]:-}
VOTE_ACCOUNT=${CFG[VOTE_ACCOUNT]:-}
LEDGER_DIR=${CFG[LEDGER_DIR]:-}
RPC_URL=${CFG[RPC_URL]:-}

# ---- 2. the validator ----
echo "== your validator"
resolve_bins
if [ -z "$VALIDATOR_UNIT" ]; then
  VALIDATOR_UNIT=$(find_unit) || ask VALIDATOR_UNIT "  validator systemd unit not found, its name" "" check_unit
fi
load_unit

if [ -z "$RPC_URL" ]; then
  port=$(unit_flag '--rpc-port' | head -1)
  RPC_URL=http://127.0.0.1:${port:-8899}
fi
if ! check_rpc "$RPC_URL" 2>/dev/null; then
  case "$(unit_flag '--expected-genesis-hash' | head -1)" in
    4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY) pub=https://api.testnet.solana.com ;;
    EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG) pub=https://api.devnet.solana.com ;;
    *) pub=https://api.mainnet-beta.solana.com ;;
  esac
  echo "  $RPC_URL does not answer (is the validator RPC off?)"
  ask RPC_URL "  RPC to use" "$pub" check_rpc
fi

try detect_vote || ask VOTE_ACCOUNT "  vote account not found in $VALIDATOR_UNIT, its address" "" check_vote
detect_vote
detect_node
try detect_identity || ask IDENTITY_KEYPAIR "  no keypair for identity $NODE in $VALIDATOR_UNIT, its path" "" check_idkey
detect_identity
try detect_ledger || ask LEDGER_DIR "  ledger not found in $VALIDATOR_UNIT, its path" "" check_dir
detect_ledger
try resolve_agave || ask VALIDATOR_BIN "  agave-validator not found, its path" "" check_exec
resolve_agave

show(){
  local active now
  active=$(active_identity)
  if [ "$active" = "$ID" ]; then now="this node is voting with it"
  elif [ -n "$active" ]; then now="spare, runs as $active"
  else now="validator not answering"
  fi
  printf '  %-10s %s\n' unit "$VALIDATOR_UNIT" solana "$SOLANA_BIN_DIR" validator "$AGAVE" \
    identity "$ID_KEY" "" "$ID" vote "$VOTE" ledger "$LEDGER" rpc "$RPC_URL" now "$now"
}
show
if ! confirm "all correct?"; then
  ask VALIDATOR_UNIT "  unit" "$VALIDATOR_UNIT" check_unit
  ask SOLANA_BIN_DIR "  solana folder" "$SOLANA_BIN_DIR" check_bindir
  ask VALIDATOR_BIN "  agave-validator" "$AGAVE" check_exec
  ask RPC_URL "  rpc" "$RPC_URL" check_rpc
  ask VOTE_ACCOUNT "  vote account" "$VOTE" check_vote
  UNIT_TEXT=""
  resolve_bins; load_unit; detect_vote; detect_node
  ask IDENTITY_KEYPAIR "  identity keypair" "$ID_KEY" check_idkey
  ask LEDGER_DIR "  ledger" "$LEDGER" check_dir
  detect_identity; detect_ledger; resolve_agave
  show
  confirm "all correct now?" || die "stopped, nothing written"
fi
CFG[VALIDATOR_UNIT]=$VALIDATOR_UNIT
CFG[SOLANA_BIN_DIR]=$SOLANA_BIN_DIR
CFG[VALIDATOR_BIN]=$AGAVE
CFG[IDENTITY_KEYPAIR]=$ID_KEY
CFG[VOTE_ACCOUNT]=$VOTE
CFG[LEDGER_DIR]=$LEDGER
CFG[RPC_URL]=$RPC_URL

# ---- 3. Telegram ----
echo "== Telegram (optional): one bot for all modules"
TG_BOT_TOKEN=${CFG[TG_BOT_TOKEN]:-}
TG_CHAT_ID=${CFG[TG_CHAT_ID]:-}
if [ -n "$TG_BOT_TOKEN" ] && ! confirm "  a bot is set (chat $TG_CHAT_ID), keep it?"; then TG_BOT_TOKEN=""; fi
if [ -z "$TG_BOT_TOKEN" ]; then
  ask TG_BOT_TOKEN "  bot token (Enter = no Telegram)" "" check_token
  TG_CHAT_ID=""
  [ -z "$TG_BOT_TOKEN" ] || ask TG_CHAT_ID "  chat id" "" check_chat
fi
CFG[TG_BOT_TOKEN]=$TG_BOT_TOKEN
CFG[TG_CHAT_ID]=$TG_CHAT_ID
if [ -n "$TG_BOT_TOKEN" ]; then
  if tg_send "volta-tools on $HOST: Telegram works"; then
    echo "  test message sent"
  else
    echo "  test message failed: check the token, the chat id, and that the bot is in the chat"
  fi
fi

# ---- 4. modules ----
echo "== modules"
mods=()
for f in "$VOLTA_HOME"/*/module.env; do
  [ -f "$f" ] || continue
  m=$(basename "$(dirname "$f")")
  about=$(sed -n 's/^# about: //p' "$f" | head -1)
  if confirm "  $m: $about. Enable?"; then
    mods+=("$m")
    if [ -f "$VOLTA_HOME/$m/setup.sh" ]; then
      # shellcheck disable=SC1090
      . "$VOLTA_HOME/$m/setup.sh"
      "${m}_setup"
    fi
  fi
done

# ---- 5. the config ----
# Print a template with the values from CFG. Only plain values, so the file stays
# safe to read as shell.
render(){
  local line k v
  while IFS= read -r line; do
    if [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      k=${BASH_REMATCH[1]}
      v=${BASH_REMATCH[2]}
      if [[ -v CFG[$k] ]]; then v=${CFG[$k]}; fi
      [[ $v =~ ^[A-Za-z0-9_./:@+,=~-]*$ ]] || die "the value of $k has unusual characters, set it by hand: $v"
      printf '%s=%s\n' "$k" "$v"
      SEEN[$k]=1
    else
      printf '%s\n' "$line"
    fi
  done < "$1"
}
new=$(mktemp "$VOLTA_HOME/.env.new.XXXX")
trap 'rm -f "$new"' EXIT
chmod 600 "$new"
{
  render "$VOLTA_HOME/lib/common.env"
  for f in "$VOLTA_HOME"/*/module.env; do echo; render "$f"; done
  extra=""
  for k in "${!CFG[@]}"; do
    if [[ ! -v SEEN[$k] ]]; then extra+="$k=${CFG[$k]}"$'\n'; fi
  done
  if [ -n "$extra" ]; then
    echo
    echo "# ---------- kept from your old config ----------"
    printf '%s' "$extra" | sort
  fi
} > "$new"

hide(){ sed 's/^\([-+ ]\{0,1\}TG_BOT_TOKEN=\).\{1,\}/\1<hidden>/'; }
if [ -f "$ENV_FILE" ] && diff -q "$ENV_FILE" "$new" >/dev/null; then
  log "config unchanged"
else
  if [ -f "$ENV_FILE" ]; then
    echo "== changes in $ENV_FILE"
    diff -u "$ENV_FILE" "$new" | tail -n +3 | hide || true
  else
    echo "== new config $ENV_FILE"
    grep -vE '^(#|$)' "$new" | hide | sed 's/^/  /'
  fi
  confirm "write it?" || die "config not written"
  if [ -f "$ENV_FILE" ]; then cp -p "$ENV_FILE" "$ENV_FILE.bak"; fi
  mv "$new" "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

# ---- 6. systemd units of the modules ----
for m in "${mods[@]}"; do
  echo "== $m"
  VOLTA_ENV=$ENV_FILE VOLTA_FROM_INSTALLER=1 "$VOLTA_HOME/$m/install.sh"
done

echo
log "done"
if [ ${#mods[@]} -gt 0 ]; then
  timers=$(printf 'volta-%s.timer ' "${mods[@]}")
  echo "  start:  systemctl enable --now ${timers% }"
  echo "  logs:   journalctl -u 'volta-*' -o cat"
fi
