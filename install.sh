#!/usr/bin/env bash
# volta-tools installer
#
# Finds what your validator runs with and asks only what it can't find: the payout
# wallets and, if you want messages, a Telegram bot. Writes one config for all modules
# (.env next to this file) and the systemd units of the modules you pick.
# Run it again any time: the current values are the defaults, changes are shown first.
# Starts nothing.
#
# No warranty: you run it at your own risk. See README.md (Disclaimer) and LICENSE.

set -euo pipefail
export LC_ALL=C

VOLTA_HOME=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
export VOLTA_HOME
# messages for a person: no timestamps, errors as "ERROR: ..."
# shellcheck disable=SC2034  # read by die() in lib/common.sh
VOLTA_UI=1
# shellcheck source=lib/common.sh
. "$VOLTA_HOME/lib/common.sh"
case "$ENV_FILE" in /*) ;; *) ENV_FILE=$PWD/$ENV_FILE ;; esac

new=""
on_exit(){ printf '%s' "$C_0" >&2; [ -z "$new" ] || rm -f "$new"; }
trap on_exit EXIT
trap 'echo; err "stopped (Ctrl+C)"; exit 130' INT

[ "$(id -u)" = 0 ] || die "run as root: it reads the validator keys and writes systemd units"
# the systemd units take these paths as they are
for p in "$VOLTA_HOME" "$ENV_FILE"; do
  [[ $p =~ ^/[A-Za-z0-9._/@+-]*$ ]] \
    || die "the path \"$p\" has a space or another unusual character: systemd can't use it. Put volta-tools (and VOLTA_ENV) under a plain path, like /root/volta-tools"
done
for c in curl flock awk diff systemctl; do
  command -v "$c" >/dev/null || die "$c is missing"
done

mods_all=""
for f in "$VOLTA_HOME"/*/module.env; do
  [ -f "$f" ] || continue
  m=$(basename "$(dirname "$f")")
  mods_all+="${mods_all:+, }$m $(volta_version "$VOLTA_HOME/$m")"
done
cat <<EOF

${C_H}volta-tools $(volta_version) installer${C_0}   ${C_DIM}modules: $mods_all${C_0}

  What's ahead: 7 short steps. Nothing is written before step 6, and no timer is started.
    1  your validator   found by itself, you only confirm it
    2  Telegram         optional, Enter skips it
    3  modules          y or n for each
    4  payout wallets   where the money goes: one wallet for all, or one per module
    5  settings         the defaults are fine; a dry run is suggested to start with
    6  config           shown in full before it is written
    7  timers           a dry run first, then the systemd timer (installed, not started)

  Have ready:
    - the payout wallet address: a live wallet you hold the key to, not on this server
    - for Telegram messages: a bot token from @BotFather and the chat id

  Keys:
    Enter    keeps the value shown in [ ]
    -        empties a value
    y, n     answer a yes/no question
    Ctrl+C   stops at any point

  ${C_BAD} NO WARRANTY ${C_0} These tools move real money: the SOL and JitoSOL of your validator.
  They are free, non-commercial and come as they are. Whatever goes wrong, a bug, my
  mistake or yours (a wrong wallet, a wrong setting), the loss is yours: I accept no
  claims and no liability. The full text is in README.md, "Disclaimer".

EOF
confirm "  I understand and accept this. Start?" || die "stopped, nothing written"

declare -A CFG=() KEEP=() RES=() SAVED=()

# ---- checks for the answers (the module setup.sh files use them too) ----
check_unit(){
  systemctl cat "${1%.service}.service" >/dev/null 2>&1 && return 0
  hint "no such unit"; return 1
}
check_bindir(){
  [ -x "$1/solana" ] && [ -x "$1/solana-keygen" ] && return 0
  hint "no solana and solana-keygen there"; return 1
}
check_rpc(){
  "$SOLANA" -u "$1" epoch-info >/dev/null 2>&1 && return 0
  hint "no answer from $(url_show "$1")"; return 1
}
check_vote(){
  if is_pubkey "$1" && "$SOLANA" vote-account "$1" -u "$RPC_URL" >/dev/null 2>&1; then return 0; fi
  hint "not a vote account"; return 1
}
check_idkey(){
  if [ -f "$1" ] && [ "$("$KEYGEN" pubkey "$1" 2>/dev/null || true)" = "$NODE" ]; then return 0; fi
  hint "not the keypair of $NODE"; return 1
}
check_dir(){
  [ -d "$1" ] && return 0
  hint "no such folder"; return 1
}
check_exec(){
  [ -x "$1" ] && return 0
  hint "not an executable file"; return 1
}
check_token(){
  if [ -z "$1" ] || [ "$1" = - ] || [[ $1 =~ ^[0-9]{5,12}:[A-Za-z0-9_-]{30,}$ ]]; then return 0; fi
  hint "that does not look like a bot token (123456789:AA...)"; return 1
}
check_chat(){
  if [[ $1 =~ ^-?[0-9]+$ || $1 =~ ^@[A-Za-z0-9_]{5,}$ ]]; then return 0; fi
  hint "a number like -1001234567890, or @channelname"; return 1
}
check_chat_opt(){ [ -z "$1" ] || [ "$1" = - ] || check_chat "$1"; }
check_payout(){
  local p
  p=$(payout_problem "$1")
  [ -z "$p" ] && return 0
  hint "$p"; return 1
}
# a module's own payout wallet: empty or - = none (it then pays to another module's)
check_payout_opt(){ [ -z "$1" ] || [ "$1" = - ] || check_payout "$1"; }
check_num(){
  [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]] && return 0
  hint "a number, like 3 or 0.83 (a dot, not a comma)"; return 1
}
check_minute(){
  if [ -z "$1" ]; then return 0; fi
  if [[ $1 =~ ^[0-9]{1,2}$ ]] && (( 10#$1 < 60 )); then return 0; fi
  hint "0..59, or - for a random minute"; return 1
}
check_jitter(){
  [[ $1 =~ ^[0-9]+(s|sec|m|min|h)?$ ]] && return 0
  hint "like 900 or 15min (no space)"; return 1
}
check_01(){
  [[ $1 =~ ^[01]$ ]] && return 0
  hint "0 or 1"; return 1
}
# "[3/7] Modules": a numbered step
step(){ printf '\n%s[%s/7] %s%s\n' "$C_H" "$1" "$2" "$C_0"; }
# Does a detection step work without asking? (runs it in a subshell, quietly)
try(){ ( "$@" ) >/dev/null 2>&1; }

# The config for a person: grouped by section, values in color, empty keys on one line,
# the Telegram token and the query of a URL (an API key) hidden. The values are compared as
# they read (env_plain), not as they are written. show_config OLD NEW (OLD empty = new).
_show_config(){
  awk -v old="$1" -v on=" ${mods[*]} " -v cH="$C_H" -v cP="$C_OK" -v cM="$C_ERR" -v cD="$C_DIM" -v c0="$C_0" '
    function val(k, v,   q) {
      if (k == "TG_BOT_TOKEN" && v != "") return "<hidden>"
      q = index(v, "?")
      if (k ~ /_URL$/ && q) return substr(v, 1, q) "<hidden>"
      return v
    }
    function flush(   i) {
      if (n > 0 || empty != "" || folded) {
        printf "\n    %s%s%s%s\n", cH, label, c0, note
        for (i = 1; i <= n; i++) print line[i]
        if (empty != "") printf "      %sleft empty:%s%s\n", cD, c0, empty
        shown++
      }
      n = 0; empty = ""; folded = 0
    }
    BEGIN {
      if (old != "") while ((getline l < old) > 0)
        if (l ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k = l; sub(/=.*/, "", k); v = l; sub(/^[^=]*=/, "", v); ov[k] = v }
    }
    /^# ---------- / {
      flush()
      label = $0; sub(/^# -+ /, "", label); sub(/ -+$/, "", label); sub(/ \(.*/, "", label)
      mod = (label != "validator" && label != "telegram" && label !~ /^kept from/)
      note = (mod && index(on, " " label " ") == 0) ? " (not enabled here: kept as it is)" : ""
      folded = (old == "" && note != "")
      next
    }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      if (folded) next
      k = $0; sub(/=.*/, "", k); v = $0; sub(/^[^=]*=/, "", v)
      if (old != "" && (k in ov)) {
        if (ov[k] == v) next
        line[++n] = sprintf("      - %s=%s%s%s", k, cM, val(k, ov[k]), c0)
        line[++n] = sprintf("      + %s=%s%s%s", k, cP, val(k, v), c0)
      } else if (v == "") {
        empty = empty " " k
      } else {
        line[++n] = sprintf("      %s%s=%s%s%s", (old != "" ? "+ " : ""), k, cP, val(k, v), c0)
      }
    }
    END { flush(); if (!shown) print "    no value changes: only the layout (comments, quotes, line ends)" }
  ' "$2"
}
show_config(){
  if [ -n "$1" ]; then _show_config <(env_plain "$1") <(env_plain "$2"); else _show_config "" <(env_plain "$2"); fi
}

# ---- the current config gives the defaults ----
# The keys volta-tools uses go to CFG. A line of your own that sets another key is kept
# as you wrote it, at the end of the new config.
if [ -f "$ENV_FILE" ]; then
  say "Found $ENV_FILE: its values are offered as the defaults."
  keys=" $(env_keys | tr '\n' ' ') "
  while IFS= read -r line || [ -n "$line" ]; do
    env_line "$line" || continue
    if [[ $keys == *" $ENV_K "* ]]; then CFG[$ENV_K]=$ENV_V; else KEEP[$ENV_K]=${line%$'\r'}; fi
  done < "$ENV_FILE"
fi
VALIDATOR_UNIT=${CFG[VALIDATOR_UNIT]:-}
SOLANA_BIN_DIR=${CFG[SOLANA_BIN_DIR]:-}
VALIDATOR_BIN=${CFG[VALIDATOR_BIN]:-}
IDENTITY_KEYPAIR=${CFG[IDENTITY_KEYPAIR]:-}
VOTE_ACCOUNT=${CFG[VOTE_ACCOUNT]:-}
LEDGER_DIR=${CFG[LEDGER_DIR]:-}
RPC_URL=${CFG[RPC_URL]:-}

# ---- 1. the validator ----
step 1 "Your validator"
resolve_bins
if [ -z "$VALIDATOR_UNIT" ]; then
  VALIDATOR_UNIT=$(find_unit) || ask VALIDATOR_UNIT "  Validator systemd unit (not found by itself)" "" check_unit
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
  warn "$(url_show "$RPC_URL") does not answer (is the validator RPC off?): offering a public RPC"
  ask RPC_URL "  RPC to use" "$pub" check_rpc
fi

try detect_vote || ask VOTE_ACCOUNT "  Vote account address (not found in $VALIDATOR_UNIT)" "" check_vote
detect_vote
detect_node
try detect_identity || ask IDENTITY_KEYPAIR "  Keypair file of identity $NODE (not found in $VALIDATOR_UNIT)" "" check_idkey
detect_identity
try detect_ledger || ask LEDGER_DIR "  Ledger folder (not found in $VALIDATOR_UNIT)" "" check_dir
detect_ledger
try resolve_agave || ask VALIDATOR_BIN "  Path to agave-validator (not found by itself)" "" check_exec
resolve_agave

show(){
  local active status
  active=$(active_identity)
  if [ "$active" = "$ID" ]; then status="this node is voting with it"
  elif [ -n "$active" ]; then status="spare, runs as $active"
  else status="validator not answering"
  fi
  say "Found:"
  printf '    %-10s %s\n' unit "$VALIDATOR_UNIT" cli "$SOLANA_BIN_DIR" validator "$AGAVE" \
    identity "$ID_KEY" "" "$ID" vote "$VOTE" ledger "$LEDGER" rpc "$(url_show "$RPC_URL")" status "$status"
}
show
if ! confirm "  Is this right?"; then
  ask VALIDATOR_UNIT "  Unit" "$VALIDATOR_UNIT" check_unit
  ask SOLANA_BIN_DIR "  Folder with solana and solana-keygen" "$SOLANA_BIN_DIR" check_bindir
  ask VALIDATOR_BIN "  agave-validator" "$AGAVE" check_exec
  ask RPC_URL "  RPC" "$RPC_URL" check_rpc
  ask VOTE_ACCOUNT "  Vote account" "$VOTE" check_vote
  UNIT_TEXT=""
  resolve_bins; load_unit; detect_vote; detect_node
  ask IDENTITY_KEYPAIR "  Identity keypair file" "$ID_KEY" check_idkey
  ask LEDGER_DIR "  Ledger folder" "$LEDGER" check_dir
  detect_identity; detect_ledger; resolve_agave
  show
  confirm "  Is it right now?" || die "stopped, nothing written"
fi
CFG[VALIDATOR_UNIT]=$VALIDATOR_UNIT
CFG[SOLANA_BIN_DIR]=$SOLANA_BIN_DIR
CFG[VALIDATOR_BIN]=$AGAVE
CFG[IDENTITY_KEYPAIR]=$ID_KEY
CFG[VOTE_ACCOUNT]=$VOTE
CFG[LEDGER_DIR]=$LEDGER
CFG[RPC_URL]=$RPC_URL

# ---- 2. Telegram ----
step 2 "Telegram (optional)"
say "One bot for all modules: payouts and problems go to its chat."
TG_BOT_TOKEN=${CFG[TG_BOT_TOKEN]:-}
TG_CHAT_ID=${CFG[TG_CHAT_ID]:-}
if [ -n "$TG_BOT_TOKEN" ] && ! confirm "  Keep the Telegram bot you have (chat $TG_CHAT_ID)?"; then TG_BOT_TOKEN=""; fi
if [ -z "$TG_BOT_TOKEN" ]; then
  ask TG_BOT_TOKEN "  Telegram bot token" "-" check_token
  [ "$TG_BOT_TOKEN" != - ] || TG_BOT_TOKEN=""
  TG_CHAT_ID=""
  [ -z "$TG_BOT_TOKEN" ] || ask TG_CHAT_ID "  Chat id for the messages" "" check_chat
fi
CFG[TG_BOT_TOKEN]=$TG_BOT_TOKEN
CFG[TG_CHAT_ID]=$TG_CHAT_ID
TG_CHAT_ALARM=${CFG[TG_CHAT_ALARM]:-}
if [ -z "$TG_BOT_TOKEN" ]; then
  TG_CHAT_ALARM=""
else
  ask TG_CHAT_ALARM "  Separate chat for errors and alarms" "${TG_CHAT_ALARM:--}" check_chat_opt "${TG_CHAT_ALARM:-same chat}"
  [ "$TG_CHAT_ALARM" != - ] || TG_CHAT_ALARM=""
fi
CFG[TG_CHAT_ALARM]=$TG_CHAT_ALARM
if [ -n "$TG_BOT_TOKEN" ]; then
  if tg_send "volta-tools on $HOST: Telegram works"; then ok "test message sent"
  else warn "test message failed: check the token, the chat id, and that the bot is in the chat"; fi
  if [ -n "$TG_CHAT_ALARM" ]; then
    if tg_send "volta-tools on $HOST: alarms come here" "$TG_CHAT_ALARM"; then ok "test alarm sent"
    else warn "test alarm failed: check the alarm chat id, and that the bot is in that chat"; fi
  fi
fi

# ---- 3. modules ----
step 3 "Modules"
mods=() mods_off=()
for f in "$VOLTA_HOME"/*/module.env; do
  [ -f "$f" ] || continue
  m=$(basename "$(dirname "$f")")
  about=$(sed -n 's/^# about: //p' "$f" | head -1)
  printf '%s %s: %s.\n' "$m" "$(volta_version "$VOLTA_HOME/$m")" "$about" | fold -s -w 96 | sed 's/ *$//; s/^/  /'
  ts=$(timer_state "$m")
  case "$ts" in
    on)  say "Installed here, and its timer is on." ;;
    off) say "Installed here, its timer is not on." ;;
  esac
  if confirm "  Enable $m?"; then
    mods+=("$m")
  else
    mods_off+=("$m")
    # the installer never stops a timer: it says what goes on running
    [ "$ts" != on ] || warn "the $m timer stays on: $m keeps running with its current settings. To turn it off: systemctl disable --now volta-$m.timer"
  fi
done

# ---- 4. payout wallets of the enabled modules ----
# A module that pays out has a <MODULE>_PAYOUT_WALLET. One is enough: a module whose
# wallet is empty pays out to another module's wallet, and warns about it.
pays=()
for m in "${mods[@]}"; do
  k=$(sed -n 's/^\([A-Z][A-Z0-9_]*_PAYOUT_WALLET\)=.*/\1/p' "$VOLTA_HOME/$m/module.env" | head -1)
  [ -z "$k" ] || pays+=("$m:$k")
done
if [ ${#pays[@]} -gt 0 ]; then
  step 4 "Payout wallets"
  say "The payout wallet must:"
  say "  - exist on-chain with some SOL on it (send it a little first)"
  say "  - be yours: you hold its key, and the key is not on this server"
  say "  - not be an exchange deposit address, the identity or the vote account"
  [ ${#pays[@]} -lt 2 ] || say "One wallet is enough: a module without its own pays out to the wallet of the other one."
  # the wallets in the config now stay the defaults, also when asked again after an ERROR
  for p in "${pays[@]}"; do k=${p#*:}; SAVED[$k]=${CFG[$k]:-}; done
  while true; do
    first="" first_m=""
    for p in "${pays[@]}"; do
      m=${p%%:*}; k=${p#*:}; shown=""
      if [ ${#pays[@]} -eq 1 ]; then
        def=${SAVED[$k]}
      else
        def=${SAVED[$k]:--}
        if [ -z "${SAVED[$k]}" ] && [ -n "$first" ]; then shown="same as $first_m"; fi
      fi
      ask v "  Wallet for $m payouts ($k)" "$def" check_payout_opt "$shown"
      [ "$v" != - ] || v=""
      CFG[$k]=$v
      if [ -n "$v" ]; then
        bal=$("$SOLANA" balance "$v" -u "$RPC_URL" 2>/dev/null) || bal="? SOL"
        ok "${v:0:4}...${v: -4} holds $bal. Check the first and last 4 characters in your wallet app."
        if [ -z "$first" ]; then first=$k; first_m=$m; fi
      fi
    done
    [ -z "$first" ] || break
    if [ ${#pays[@]} -eq 1 ]; then err "no payout wallet: enter one"; else err "no payout wallet: enter at least one"; fi
  done
  for p in "${pays[@]}"; do
    m=${p%%:*}; k=${p#*:}
    [ -n "${CFG[$k]}" ] || warn "$k is empty: $m pays out to $first ${CFG[$first]}"
  done
fi

# ---- 5. module settings ----
for m in "${mods[@]}"; do
  [ -f "$VOLTA_HOME/$m/setup.sh" ] || continue
  step 5 "Settings: $m"
  # shellcheck disable=SC1090
  . "$VOLTA_HOME/$m/setup.sh"
  "${m}_setup"
done

# ---- 6. the config ----
# Print a template with the values from CFG, each written to read back as it is
# (env_quote): nothing in it can run as a command, even when a shell reads the file.
render(){
  local line
  while IFS= read -r line; do
    if env_line "$line"; then
      if [[ -v CFG[$ENV_K] ]]; then ENV_V=${CFG[$ENV_K]}; fi
      printf '%s=%s\n' "$ENV_K" "$(env_quote "$ENV_V")"
    else
      printf '%s\n' "$line"
    fi
  done < "$1"
}
new=$(mktemp "$(dirname "$ENV_FILE")/.env.new.XXXX")
chmod 600 "$new"
{
  render "$VOLTA_HOME/lib/common.env"
  for f in "$VOLTA_HOME"/*/module.env; do echo; render "$f"; done
  # your own lines (keys volta-tools does not use), as you wrote them
  if [ ${#KEEP[@]} -gt 0 ]; then
    echo
    echo "# ---------- kept from your old config ----------"
    printf '%s\n' "${KEEP[@]}" | sort
  fi
} > "$new"

step 6 "Config: $ENV_FILE"
if [ -f "$ENV_FILE" ] && diff -q "$ENV_FILE" "$new" >/dev/null; then
  say "Config unchanged."
else
  if [ -f "$ENV_FILE" ]; then
    say "What changes (- old, + new):"
    show_config "$ENV_FILE" "$new"
  else
    say "A new config:"
    show_config "" "$new"
  fi
  echo
  confirm "  Write this config?" || die "config not written"
  bak=""
  if [ -f "$ENV_FILE" ]; then
    bak=$ENV_FILE.bak-$(date -u +%Y%m%d-%H%M%S)
    cp -p "$ENV_FILE" "$bak"
    # keep the last 5 copies: the names sort by time
    shopt -s nullglob; baks=("$ENV_FILE".bak-*); shopt -u nullglob
    if [ ${#baks[@]} -gt 5 ]; then rm -f -- "${baks[@]:0:${#baks[@]}-5}"; fi
  fi
  mv "$new" "$ENV_FILE"
  new=""
  if [ -n "$bak" ]; then ok "written. The old one is kept as $bak"; else ok "written."; fi
fi
chmod 600 "$ENV_FILE"

# ---- 7. systemd units of the modules ----
# A module installer ends with 0 when it wrote the timer, and with 3 when you said no.
for m in "${mods[@]}"; do
  step 7 "Timers: $m"
  rc=0
  VOLTA_ENV=$ENV_FILE VOLTA_FROM_INSTALLER=1 "$VOLTA_HOME/$m/install.sh" || rc=$?
  case $rc in
    0) RES[$m]=inst ;;
    3) RES[$m]=skip ;;
    *) exit "$rc" ;;
  esac
done

# ---- what now ----
printf '\n%sDone.%s\n' "$C_H" "$C_0"
[ ${#mods[@]} -gt 0 ] || say "No module is enabled. Run the installer again to enable one."
start=() timers=()
for m in "${mods[@]}"; do
  ts=$(timer_state "$m")
  case "${RES[$m]}:$ts" in
    inst:on)  say "The $m timer was on already: it stays on, and its next run takes the new config." ;;
    inst:*)   start+=("$m") ;;
    skip:on)  say "The $m timer from before stays on: its next run takes the new config." ;;
    skip:off) say "The $m timer from before stays as it was: installed, not on." ;;
    *)        say "The $m timer is not installed: run the installer again to add it." ;;
  esac
  [ "$ts" = none ] || timers+=("$m")
done
if [ ${#start[@]} -gt 0 ]; then
  if [ ${#start[@]} -gt 1 ]; then say "Nothing is running yet. When the dry runs above look right:"
  else say "Nothing is running yet. When the dry run above looks right:"; fi
  for m in "${start[@]}"; do
    printf '    %-46s # %s\n' "systemctl enable --now volta-$m.timer" "start the hourly $m runs"
  done
  printf '    %-46s # %s\n' "journalctl -u 'volta-*' -o cat" "what they did"
fi
for m in "${timers[@]}"; do
  k=$(printf '%s' "$m" | tr '[:lower:]' '[:upper:]')_DRY_RUN
  if [ "${CFG[$k]:-1}" = 1 ]; then say "$m stays a dry run until you set $k=0 in $ENV_FILE."
  else warn "$m is not a dry run: its runs send money ($k=0)."; fi
done
# modules not enabled here that still have a timer from before
for m in "${mods_off[@]}"; do
  case "$(timer_state "$m")" in
    on)  warn "$m is not enabled here, but its timer is on: $m keeps running with its current settings. To turn it off: systemctl disable --now volta-$m.timer" ;;
    off) say "volta-$m.timer from before is still installed, but not on: $m does not run. To remove it: rm /etc/systemd/system/volta-$m.service /etc/systemd/system/volta-$m.timer" ;;
  esac
done
