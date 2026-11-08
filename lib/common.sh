#!/usr/bin/env bash
# volta-tools: shared helpers. Sourced by the installer and the modules, not run on its own.
# shellcheck disable=SC2034  # the variables set here are used by the callers

# The code: the folder that holds lib/ and the modules, with the templates of the config.
VOLTA_SRC=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
# Repo root: the code folder, unless VOLTA_HOME says otherwise (the tests keep their state apart).
VOLTA_HOME=${VOLTA_HOME:-$VOLTA_SRC}
# Config: .env in the repo root, or whatever file VOLTA_ENV points to.
ENV_FILE=${VOLTA_ENV:-$VOLTA_HOME/.env}
# Small state files, e.g. the last alert of each module.
STATE_DIR=$VOLTA_HOME/.state
HOST=${HOSTNAME%%.*}

# Version from the VERSION file in a folder: a module's folder, or the root
# (the default) for the core, that is install.sh and lib/.
volta_version(){
  local f=${1:-$VOLTA_HOME}/VERSION
  if [ -f "$f" ]; then tr -d ' \r\n' < "$f"; else printf unknown; fi
}

# Colors only when a person sits at a terminal, never in logs. NO_COLOR=1 turns them off.
C_Q="" C_IN="" C_OK="" C_H="" C_WARN="" C_ERR="" C_BAD="" C_DIM="" C_0=""
if [ -t 0 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  _nc=$(tput colors 2>/dev/null) || _nc=8
  if [[ $_nc =~ ^[0-9]+$ ]] && (( _nc >= 256 )); then C_Q=$'\e[1;38;5;46m'; else C_Q=$'\e[1;32m'; fi
  C_OK=$C_Q C_H=$'\e[1m' C_WARN=$'\e[1;33m' C_ERR=$'\e[1;31m' C_BAD=$'\e[1;97;41m' C_DIM=$'\e[2m' C_0=$'\e[0m'
  C_IN=$'\e[1;97m'    # what you type: the [y/n] and [default] hints and your answer
  unset _nc
fi
# The same colors inside a readline prompt, marked with \001 \002 so readline knows they
# take no room on the screen. Plain variables: building a prompt starts no subshell, so a
# Ctrl+C just before a question is never held back until the question is answered.
R_Q="" R_IN="" R_0=""
if [ -n "$C_0" ]; then R_Q=$'\001'$C_Q$'\002' R_IN=$'\001'$C_IN$'\002' R_0=$'\001'$C_0$'\002'; fi

# The installers (VOLTA_UI=1) read the answers with UTF-8 rules, so a key typed on a
# non-Latin layout comes in as one character (and gets a hint), not as a Meta key.
# C.UTF-8 sorts and matches like C.
if [ -n "${VOLTA_UI:-}" ] && locale -a 2>/dev/null | grep -ix 'c\.utf-\{0,1\}8' >/dev/null; then
  export LC_ALL=C.UTF-8
fi

log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
ok(){ printf '  %sOK:%s %s\n' "$C_OK" "$C_0" "$*"; }
warn(){ printf '  %sWARN:%s %s\n' "$C_WARN" "$C_0" "$*"; }
err(){ printf '  %sERROR:%s %s\n' "$C_ERR" "$C_0" "$*"; }
say(){ printf '  %s\n' "$*"; }
# why an answer was not taken, right under the question
hint(){ printf '    %s%s%s\n' "$C_WARN" "$*" "$C_0" >&2; }

# Log the error, let the caller react (a module may define on_die), stop.
die(){
  # VOLTA_UI=1 (the installers): for a person, no timestamp
  if [ -n "${VOLTA_UI:-}" ]; then err "$*" >&2; else log "${C_ERR}ERROR:${C_0} $*" >&2; fi
  if declare -F on_die >/dev/null; then on_die "$*" || true; fi
  exit 1
}

# ---- the config ----
# KEY=value lines and # comments. It is never run as shell: a value is taken as written,
# so nothing in the file can run a command. A value is bare (up to a " #" comment), in
# "double quotes" (\" \\ \$ \` are the escapes) or in 'single quotes' (taken as is).
# A CR at the end of a line (a file saved on Windows) is dropped.

# env_line LINE: when LINE sets a key, ENV_K is the key and ENV_V the value.
env_line(){
  local l=${1%$'\r'} r c out="" i=1 n
  [[ $l =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 1
  ENV_K=${BASH_REMATCH[2]} r=${BASH_REMATCH[3]}
  r=${r#"${r%%[![:space:]]*}"}
  case "$r" in
    \"*)
      n=${#r}
      while (( i < n )); do
        c=${r:i:1}
        if [ "$c" = \\ ] && (( i + 1 < n )); then
          case "${r:i+1:1}" in \"|\\|\$|\`) out+=${r:i+1:1}; i=$(( i + 2 )); continue ;; esac
        fi
        if [ "$c" = \" ]; then ENV_V=$out; return 0; fi
        out+=$c; i=$(( i + 1 ))
      done
      ENV_V=$r ;;                         # no closing quote: as written, for the checks to see
    \'*)
      r=${r:1}
      if [[ $r == *\'* ]]; then ENV_V=${r%%\'*}; else ENV_V=\'$r; fi ;;
    *)
      r=${r%%[[:space:]]#*}               # a " # comment" at the end
      ENV_V=${r%"${r##*[![:space:]]}"} ;;
  esac
}

# env_quote VALUE: how a value is written to the config: bare when it is plain, else in
# double quotes with \ " $ ` escaped. Reads back as the same value, here and in a shell.
env_quote(){
  local v=$1
  if [[ $v =~ ^[A-Za-z0-9_./:@%+,=-]*$ ]]; then printf '%s' "$v"; return 0; fi
  v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}; v=${v//\`/\\\`}
  printf '"%s"' "$v"
}

# The keys of the templates, lib/common.env and each */module.env: the keys volta-tools uses.
env_keys(){ sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$VOLTA_SRC/lib/common.env" "$VOLTA_SRC"/*/module.env 2>/dev/null || true; }

# Read the config into shell variables: only the keys of the templates.
load_env(){
  [ -f "$ENV_FILE" ] || die "no config at $ENV_FILE, run $VOLTA_HOME/install.sh first"
  local line keys
  keys=" $(env_keys | tr '\n' ' ') "
  while IFS= read -r line || [ -n "$line" ]; do
    env_line "$line" || continue
    [[ $keys == *" $ENV_K "* ]] || continue
    printf -v "$ENV_K" '%s' "$ENV_V"
  done < "$ENV_FILE"
}

# env_plain FILE: the file with each value as it reads (no quotes, no comment at the end),
# to compare what the values are rather than how they are written.
env_plain(){
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if env_line "$line"; then printf '%s=%s\n' "$ENV_K" "$ENV_V"; else printf '%s\n' "${line%$'\r'}"; fi
  done < "$1"
}

# A URL for messages: a query (?api-key=...) and a user:password@ part are hidden.
url_show(){
  local u=$1
  case "$u" in *\?*) u="${u%%\?*}?..." ;; esac
  if [[ $u =~ ^([A-Za-z]+://)[^/@]*@(.*)$ ]]; then u="${BASH_REMATCH[1]}...@${BASH_REMATCH[2]}"; fi
  printf '%s' "$u"
}

# ---- questions ----

has_non_ascii(){ [ -n "$(printf '%s' "$1" | tr -d '\000-\177')" ]; }

# Before a question, at a terminal: what was typed ahead. An empty line (a stray Enter, the
# \n of a pasted \r\n) is dropped, so it can't answer the question. A line typed ahead is the
# answer (TYPED, TYPED_DONE=1); a part of one is put back to finish (TYPED). Also: no Tab
# completion (a list of files) in the answers. Piped answers are all kept as they come.
drain_input(){
  TYPED="" TYPED_DONE=""
  [ -t 0 ] || return 0
  if [ -z "${_volta_rl:-}" ]; then bind 'set disable-completion on' 2>/dev/null || true; _volta_rl=1; fi
  local c
  while IFS= read -r -s -t 0.03 -n 1 -d '' c; do
    if [ "$c" = $'\n' ] || [ "$c" = $'\r' ]; then
      [ -z "$TYPED" ] || { TYPED_DONE=1; return 0; }
      continue
    fi
    TYPED+=$c
  done
}

# Clean a typed or pasted answer: bracketed-paste marks ([200~ ... [201~, also copied as
# the text ^[[200~), arrow keys and other escape sequences, CR from Windows, other control
# characters, tabs, no-break and zero-width spaces, spaces around it, and quotes around it.
clean_input(){
  local s
  s=$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[A-Za-z~]//g; s/\^\[\[20[01]~//g; s/\[20[01]~//g' | tr -d '\000-\010\013-\037\177')
  s=${s//$'\xc2\xa0'/ }; s=${s//$'\xe2\x80\x8b'/}; s=${s//$'\xef\xbb\xbf'/}; s=${s//$'\t'/ }
  s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}
  case "$s" in
    \"*\"|\'*\'|\`*\`) s=${s:1:${#s}-2}; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"} ;;
  esac
  printf '%s' "$s"
}

# Ask until the answer is y or n. No input at all (EOF, Ctrl+D) stops everything: it is
# never taken as an answer. read -e: arrow keys and Backspace work, a paste comes in clean.
confirm(){
  local a p="${R_Q}$1${R_0} ${R_IN}[y/n]${R_0} ${R_IN}" q="${C_Q}$1${C_0} ${C_IN}[y/n]${C_0} ${C_IN}"
  while true; do
    drain_input
    if [ -n "$TYPED_DONE" ]; then printf '%s%s\n' "$q" "$TYPED" >&2; a=$TYPED
    elif ! read -r -e -i "$TYPED" -p "$p" a; then printf '%s\n' "$C_0" >&2; die "no input, stopped"; fi
    printf '%s' "$C_0" >&2
    a=$(clean_input "$a")
    case "$a" in
      y|Y|yes|Yes|YES) return 0 ;;
      n|N|no|No|NO) return 1 ;;
    esac
    if has_non_ascii "$a"; then hint "type y or n (is the keyboard on English?)"; else hint "type y or n"; fi
  done
}

# ask VAR "question" [default] [check] [shown]: Enter keeps the default, - empties the value
# (so a default of - means none). "shown" is how the default appears in [ ]: a default of -
# shows as none, an empty one shows nothing. Asks again while the check says no (the check
# gets the value, a - already made empty). No input at all (EOF, Ctrl+D) stops everything.
ask(){
  local _var=$1 _q=$2 _def=${3:-} _check=${4:-} _shown=${5:-} _a _p _pp
  [ -n "$_shown" ] || _shown=$_def
  [ "$_shown" != - ] || _shown=none
  _p="${R_Q}$_q${R_0}" _pp="${C_Q}$_q${C_0}"
  [ -z "$_shown" ] || { _p+=" ${R_IN}[$_shown]${R_0}"; _pp+=" ${C_IN}[$_shown]${C_0}"; }
  _p+=": ${R_IN}" _pp+=": ${C_IN}"
  while true; do
    drain_input
    if [ -n "$TYPED_DONE" ]; then printf '%s%s\n' "$_pp" "$TYPED" >&2; _a=$TYPED
    elif ! read -r -e -i "$TYPED" -p "$_p" _a; then printf '%s\n' "$C_0" >&2; die "no input, stopped"; fi
    printf '%s' "$C_0" >&2
    _a=$(clean_input "$_a")
    _a=${_a:-$_def}
    [ "$_a" != - ] || _a=""
    if has_non_ascii "$_a"; then hint "it has non-Latin characters: check the keyboard layout, or what you copied"; continue; fi
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
  is_pubkey "$NODE" || die "cannot read vote account $VOTE via $(url_show "$RPC_URL")"
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

# payout_for <MODULE>: PAYOUT is the module's own <MODULE>_PAYOUT_WALLET or, if that is
# empty, the first other *_PAYOUT_WALLET set in the config (another module's wallet).
# PAYOUT_FROM is the setting it came from. Fails when there is none at all.
payout_for(){
  local own=$1_PAYOUT_WALLET k
  PAYOUT=${!own:-}; PAYOUT_FROM=$own
  [ -z "$PAYOUT" ] || return 0
  while IFS= read -r k; do
    if [ "$k" != "$own" ] && [ -n "${!k:-}" ]; then PAYOUT=${!k}; PAYOUT_FROM=$k; return 0; fi
  done < <(sed -n 's/^\([A-Z][A-Z0-9_]*_PAYOUT_WALLET\)=.*/\1/p' "$ENV_FILE")
  return 1
}

# The characters of an address that base58 never has, each once and in quotes: "0" "l".
# Non-Latin letters are left out (has_non_ascii tells about them).
bad_chars(){
  local s c seen="" out=""
  s=$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\377')
  while [ -n "$s" ]; do
    c=${s:0:1}; s=${s:1}
    case "$c" in [1-9A-HJ-NP-Za-km-z]) continue ;; esac
    case "$seen" in *"$c"*) continue ;; esac
    seen+=$c; out+="${out:+ }\"$c\""
  done
  printf '%s' "$out"
}

# Why an address can't be a payout wallet; prints nothing if it can.
# It must exist on-chain as a regular wallet, so a typo can never swallow SOL.
payout_problem(){
  local a=$1 out owner bad n
  case "$a" in *[[:space:]]*) echo "not an address: it has a space inside (two values pasted?)"; return 0 ;; esac
  bad=$(bad_chars "$a")
  if has_non_ascii "$a"; then
    echo "not an address: it has non-Latin letters (check the keyboard layout, or what you copied)${bad:+, and $bad}"; return 0
  fi
  if [ -n "$bad" ]; then echo "not an address: it has characters an address never has: $bad"; return 0; fi
  n=${#a}
  if [ "$n" -lt 32 ] || [ "$n" -gt 44 ]; then
    if [ "$n" = 1 ]; then n="1 character"; else n="$n characters"; fi
    echo "not an address: $n, a Solana address has 32 to 44"; return 0
  fi
  if [ "$a" = "${ID:-}" ] || [ "$a" = "${VOTE:-}" ]; then
    echo "it must be another wallet, not the identity or the vote account"; return 0
  fi
  out=$("$SOLANA" account "$a" -u "$RPC_URL" --output json 2>&1) || true
  owner=$(grep -oP '"owner":\s*"\K[^"]+' <<< "$out") || true
  if [ -z "$owner" ]; then
    case "$out" in
      *AccountNotFound*) echo "it does not exist on-chain: check it for a typo (a missing or extra character), or send it a little SOL first" ;;
      *"Invalid value"*) echo "not a valid address: check it for a typo (a missing or extra character)" ;;
      *) echo "cannot check it on-chain via $(url_show "$RPC_URL"): $(tail -1 <<< "$out")" ;;
    esac
    return 0
  fi
  [ "$owner" = 11111111111111111111111111111111 ] || echo "it is not a regular wallet (owner $owner)"
}

# ---- Telegram (optional) ----

# tg_send "text" [chat]: plain-text message to the chat, TG_CHAT_ID by default.
# Quiet no-op without TG settings.
# The token goes to curl through stdin, so it never shows up in the process list.
tg_send(){
  if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then return 0; fi
  local code
  code=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_BOT_TOKEN" \
    | curl -s -m 15 -K - -o /dev/null -w '%{http_code}' \
        --data-urlencode "chat_id=${2:-$TG_CHAT_ID}" --data-urlencode "text=$1") || true
  [ "$code" = 200 ] && return 0
  [ -n "${VOLTA_UI:-}" ] || log "WARN: Telegram did not take the message (HTTP ${code:-none})" >&2
  return 1
}

# alert <module> "text": a problem goes to Telegram (TG_CHAT_ALARM, else TG_CHAT_ID)
# once, and again only when it changes.
alert(){
  local f=$STATE_DIR/$1.alert
  mkdir -p "$STATE_DIR"
  if [ -f "$f" ] && [ "$(cat "$f")" = "$2" ]; then return 0; fi
  printf '%s' "$2" > "$f"
  tg_send "$1 on $HOST: $2" "${TG_CHAT_ALARM:-}" || true
}

# alert_clear <module>: after a clean run, one "OK again" if there was a problem before.
alert_clear(){
  local f=$STATE_DIR/$1.alert
  [ -f "$f" ] || return 0
  rm -f "$f"
  tg_send "$1 on $HOST: OK again" "${TG_CHAT_ALARM:-}" || true
}

# ---- systemd timers of the modules ----

# timer_state MODULE: on (its timer is enabled or running), off (installed, not on), none.
timer_state(){
  local t=volta-$1.timer
  if [ ! -f "/etc/systemd/system/$t" ]; then echo none
  elif systemctl is-enabled --quiet "$t" 2>/dev/null || systemctl is-active --quiet "$t" 2>/dev/null; then echo on
  else echo off; fi
}
