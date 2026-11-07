#!/usr/bin/env bash
# volta-tools: shared helpers. Sourced by the installer and the modules, not run on its own.
# shellcheck disable=SC2034  # the variables set here are used by the callers

# Repo root: the folder that holds lib/ and the modules.
VOLTA_HOME=${VOLTA_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}
# Config: .env in the repo root, or whatever file VOLTA_ENV points to.
ENV_FILE=${VOLTA_ENV:-$VOLTA_HOME/.env}
# Small state files, e.g. the last alert of each module.
STATE_DIR=$VOLTA_HOME/.state
HOST=${HOSTNAME%%.*}

log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Log the error, let the caller react (a module may define on_die), stop.
die(){
  log "ERROR: $*" >&2
  if declare -F on_die >/dev/null; then on_die "$*" || true; fi
  exit 1
}

# Read the config. CR characters are dropped, so a file saved on Windows still works.
load_env(){
  [ -f "$ENV_FILE" ] || die "no config at $ENV_FILE, run $VOLTA_HOME/install.sh first"
  # shellcheck disable=SC1090
  . <(tr -d '\r' < "$ENV_FILE")
}

# ---- questions ----

# Ask until the answer is y or n. No input at all (EOF) counts as no.
confirm(){
  local a
  while true; do
    read -r -p "$1 [y/n] " a || { echo; return 1; }
    case "$a" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
    esac
  done
}

# ask VAR "question" [default] [check]: Enter keeps the default. Asks again while
# the check function says no. No input at all (EOF) stops everything.
ask(){
  local _var=$1 _q=$2 _def=${3:-} _check=${4:-} _a
  while true; do
    if [ -n "$_def" ]; then
      read -r -p "$_q [$_def]: " _a || die "no input, stopped"
    else
      read -r -p "$_q: " _a || die "no input, stopped"
    fi
    _a=${_a:-$_def}
    if [ -z "$_check" ] || "$_check" "$_a"; then
      printf -v "$_var" '%s' "$_a"
      return 0
    fi
  done
}

is_pubkey(){ [[ ${1:-} =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]]; }
is_uint(){ [[ ${1:-} =~ ^[0-9]+$ ]]; }
lamports(){ awk -v s="$1" 'BEGIN{printf "%d", s*1e9+0.5}'; }
sol(){ awk -v l="$1" 'BEGIN{printf "%.9f", l/1e9}'; }

# ---- binaries ----

# solana and solana-keygen.
# Order: SOLANA_BIN_DIR from the config, then PATH, then the default install dir.
resolve_bins(){
  local d c
  c=$(command -v solana 2>/dev/null || true)
  for d in "${SOLANA_BIN_DIR:-}" "${c%/*}" "$HOME/.local/share/solana/install/active_release/bin"; do
    if [ -n "$d" ] && [ -x "$d/solana" ]; then SOLANA_BIN_DIR=$d; break; fi
  done
  [ -x "${SOLANA_BIN_DIR:-/nonexistent}/solana" ] || die "solana CLI not found, set SOLANA_BIN_DIR in $ENV_FILE"
  SOLANA=$SOLANA_BIN_DIR/solana
  KEYGEN=$SOLANA_BIN_DIR/solana-keygen
  [ -x "$KEYGEN" ] || die "solana-keygen not found in $SOLANA_BIN_DIR"
}

# agave-validator, only needed to ask the local validator who it runs as.
# Order: VALIDATOR_BIN from the config, next to solana, the one in the unit, PATH.
resolve_agave(){
  local c=""
  if [ -n "${VALIDATOR_BIN:-}" ]; then
    c=$VALIDATOR_BIN
  elif [ -x "$SOLANA_BIN_DIR/agave-validator" ]; then
    c=$SOLANA_BIN_DIR/agave-validator
  else
    c=$(printf '%s\n' "$UNIT_TEXT" | grep -oP '(?<![\w/.-])/\S*/agave-validator(?=\s|$)' | head -1 || true)
    [ -n "$c" ] || c=$(command -v agave-validator 2>/dev/null || true)
  fi
  [ -n "$c" ] && [ -x "$c" ] || die "agave-validator not found, set VALIDATOR_BIN in $ENV_FILE"
  AGAVE=$c
}

# ---- the validator's systemd unit ----
UNIT_TEXT=""
VALIDATOR_UNIT=${VALIDATOR_UNIT:-}

# The first validator unit that exists on this server.
find_unit(){
  local cand
  for cand in jito agave anza solana sol validator agave-validator solana-validator; do
    if systemctl cat "$cand.service" >/dev/null 2>&1; then echo "$cand.service"; return 0; fi
  done
  return 1
}

# Read the unit once. If ExecStart runs a start script, its text is read too,
# because that is where the flags usually are.
load_unit(){
  [ -n "$UNIT_TEXT" ] && return 0
  local u line tok magic
  local -a toks
  u=${VALIDATOR_UNIT:-}
  if [ -z "$u" ]; then u=$(find_unit) || die "validator unit not found, set VALIDATOR_UNIT in $ENV_FILE"; fi
  u=${u%.service}.service
  UNIT_TEXT=$(systemctl cat "$u" 2>/dev/null) || die "cannot read $u"
  VALIDATOR_UNIT=$u
  line=$(printf '%s\n' "$UNIT_TEXT" | sed -n 's/^ExecStart=[-@+!:]*//p' | tail -1)
  read -r -a toks <<< "$line"
  for tok in "${toks[@]}"; do
    [ -f "$tok" ] || continue
    magic=$(head -c4 "$tok" | od -An -tx1 | tr -d ' \n')
    [ "$magic" = 7f454c46 ] && continue          # a binary, not a script
    UNIT_TEXT+=$'\n'$(cat "$tok")
  done
}

# All values of a flag, e.g. unit_flag '--ledger|-l'. Commented lines are ignored.
unit_flag(){
  load_unit
  printf '%s\n' "$UNIT_TEXT" | grep -v '^[[:space:]]*#' \
    | grep -oP -- '(?<![\w-])(?:'"$1"')(?:\s+|=)\K[^\s\\]+' || true
}

# Make a path from the unit absolute: relative paths are tried
# from WorkingDirectory first, then from $HOME.
unit_path(){
  local p=$1 wd d
  case "$p" in /*) printf '%s\n' "$p"; return 0 ;; esac
  wd=$(printf '%s\n' "$UNIT_TEXT" | sed -n 's/^WorkingDirectory=-\{0,1\}//p' | tail -1)
  [ "$wd" = "~" ] && wd=$HOME
  for d in "$wd" "$HOME"; do
    if [ -n "$d" ] && [ -e "$d/$p" ]; then printf '%s\n' "$d/$p"; return 0; fi
  done
  printf '%s\n' "$p"
}

# ---- what the validator runs with ----

# VOTE: the vote account address, from VOTE_ACCOUNT or --vote-account in the unit.
detect_vote(){
  local v=${VOTE_ACCOUNT:-}
  if [ -z "$v" ]; then
    load_unit
    v=$(unit_flag '--vote-account' | head -1)
    [ -n "$v" ] || die "no --vote-account in $VALIDATOR_UNIT, set VOTE_ACCOUNT in $ENV_FILE"
    is_pubkey "$v" || v=$(unit_path "$v")
  fi
  if ! is_pubkey "$v"; then
    [ -f "$v" ] || die "vote account is neither an address nor a keypair file: $v"
    v=$("$KEYGEN" pubkey "$v") || die "cannot read the vote account keypair $v"
  fi
  VOTE=$v
}

# NODE: the identity the vote account belongs to on-chain.
detect_node(){
  NODE=$("$SOLANA" vote-account "$VOTE" -u "$RPC_URL" 2>/dev/null | awk '/^Validator Identity:/{print $3}') || true
  is_pubkey "$NODE" || die "cannot read vote account $VOTE via $RPC_URL"
}

# ID_KEY, ID: the identity keypair. IDENTITY_KEYPAIR, or the --authorized-voter /
# --identity keypair in the unit that matches NODE (a failover spare runs a fake --identity).
detect_identity(){
  local k
  ID_KEY=${IDENTITY_KEYPAIR:-}
  if [ -z "$ID_KEY" ]; then
    load_unit
    while IFS= read -r k; do
      k=$(unit_path "$k")
      [ -f "$k" ] || continue
      if [ "$("$KEYGEN" pubkey "$k" 2>/dev/null || true)" = "$NODE" ]; then ID_KEY=$k; break; fi
    done < <(unit_flag '--authorized-voter'; unit_flag '--identity|-i')
    [ -n "$ID_KEY" ] || die "no keypair for identity $NODE in $VALIDATOR_UNIT (--authorized-voter, --identity), set IDENTITY_KEYPAIR in $ENV_FILE"
  fi
  [ -f "$ID_KEY" ] || die "identity keypair not found: $ID_KEY"
  ID=$("$KEYGEN" pubkey "$ID_KEY") || die "cannot read identity keypair $ID_KEY"
  [ "$ID" = "$NODE" ] || die "identity keypair $ID_KEY is $ID, but vote account $VOTE belongs to $NODE"
}

# LEDGER: from LEDGER_DIR or --ledger in the unit.
detect_ledger(){
  LEDGER=${LEDGER_DIR:-}
  if [ -z "$LEDGER" ]; then
    load_unit
    LEDGER=$(unit_flag '--ledger|-l' | head -1)
    [ -n "$LEDGER" ] || die "no --ledger in $VALIDATOR_UNIT, set LEDGER_DIR in $ENV_FILE"
    LEDGER=$(unit_path "$LEDGER")
  fi
}

# Who the local validator runs as right now (empty if it does not answer).
active_identity(){ "$AGAVE" -l "$LEDGER" contact-info 2>/dev/null | awk '/^Identity:/{print $2}' || true; }

# Why an address can't be a payout wallet; prints nothing if it can.
# It must exist on-chain as a plain wallet, so a typo can never swallow SOL.
payout_problem(){
  local a=$1 owner
  if ! is_pubkey "$a"; then echo "not an address"; return 0; fi
  if [ "$a" = "${ID:-}" ] || [ "$a" = "${VOTE:-}" ]; then
    echo "it must be another wallet, not the identity or the vote account"; return 0
  fi
  owner=$("$SOLANA" account "$a" -u "$RPC_URL" --output json 2>/dev/null \
    | grep -oP '"owner":\s*"\K[^"]+') || true
  if [ -z "$owner" ]; then echo "it does not exist on-chain, send any small amount to it first"; return 0; fi
  if [ "$owner" != 11111111111111111111111111111111 ]; then echo "it is not a plain wallet (owner $owner)"; fi
}

# ---- Telegram (optional) ----

# Plain-text message to TG_CHAT_ID. Quiet no-op without TG settings.
# The token goes to curl through stdin, so it never shows up in the process list.
tg_send(){
  if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then return 0; fi
  local code
  code=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_BOT_TOKEN" \
    | curl -s -m 15 -K - -o /dev/null -w '%{http_code}' \
        --data-urlencode "chat_id=$TG_CHAT_ID" --data-urlencode "text=$1") || true
  [ "$code" = 200 ] && return 0
  log "WARN: Telegram did not take the message (HTTP ${code:-none})" >&2
  return 1
}

# alert <module> "text": a problem goes to Telegram once, and again only when it changes.
alert(){
  local f=$STATE_DIR/$1.alert
  mkdir -p "$STATE_DIR"
  if [ -f "$f" ] && [ "$(cat "$f")" = "$2" ]; then return 0; fi
  printf '%s' "$2" > "$f"
  tg_send "$1 on $HOST: $2" || true
}

# alert_clear <module>: after a clean run, one "OK again" if there was a problem before.
alert_clear(){
  local f=$STATE_DIR/$1.alert
  [ -f "$f" ] || return 0
  rm -f "$f"
  tg_send "$1 on $HOST: OK again" || true
}
