#!/usr/bin/env bash
# volta-tools / bamboost: installer questions. Sourced by install.sh, which provides
# ask, confirm, say, warn, hint, the check_* functions, CFG (config values) and the
# validator unit helpers. The payout wallet is asked by install.sh itself.
# shellcheck disable=SC2154,SC2004  # CFG: an associative array, from install.sh

# default value of a bamboost setting, from module.env
bamboost_default(){ sed -n "s/^$1=//p" "$VOLTA_HOME/bamboost/module.env"; }
bamboost_check_url(){
  local re='^https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$'
  [[ $1 =~ $re ]] && return 0
  hint "an http(s) URL, like https://api.mainnet-beta.solana.com"; return 1
}
bamboost_check_hours(){
  if [ -z "$1" ]; then return 0; fi
  if [[ $1 =~ ^[0-9]{1,2}$ ]] && (( 10#$1 <= 72 )); then return 0; fi
  hint "whole hours 0..72, or - for a random one"; return 1
}
bamboost_check_backup(){
  if [[ $1 =~ ^[0-9]{1,2}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 19 )); then return 0; fi
  hint "epochs, 1..19"; return 1
}
bamboost_check_tz(){
  if [ -z "$1" ]; then return 0; fi
  if [[ $1 =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] && [ -f "/usr/share/zoneinfo/$1" ]; then return 0; fi
  hint "a time zone like Asia/Tokyo, or - for the server's time"; return 1
}

# the settings, each with the check of its answer
BAMBOOST_SETTINGS="BAMBOOST_RPC_URL:bamboost_check_url BAMBOOST_CURRENT_AFTER_HOURS:bamboost_check_hours
  BAMBOOST_BACKUP_AFTER:bamboost_check_backup BAMBOOST_TIMER_MINUTE:check_minute
  BAMBOOST_TIMER_JITTER:check_jitter BAMBOOST_LOG_TZ:bamboost_check_tz BAMBOOST_TG:check_01"

# bamboost_ask NAME:check: one setting, with the value it has now as the default
bamboost_ask(){
  local name=${1%%:*} v shown=""
  if [ -z "${CFG[$name]:-}" ]; then
    case "$name" in
      BAMBOOST_LOG_TZ) shown="server time" ;;
      BAMBOOST_CURRENT_AFTER_HOURS|BAMBOOST_TIMER_MINUTE) shown=random ;;
    esac
  fi
  ask v "  $name" "${CFG[$name]:-}" "${1##*:}" "$shown"
  CFG[$name]=$v
}

bamboost_setup(){
  local s k v
  command -v python3 >/dev/null || die "bamboost needs python3"
  case "$(unit_flag '--expected-genesis-hash' | head -1)" in
    4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY|EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG)
      warn "this validator is not on mainnet, bamboost will find nothing to claim" ;;
  esac
  # each value as it is now (from the config, or the default for an empty one) must pass
  # its check, or it is asked again
  for s in $BAMBOOST_SETTINGS; do
    k=${s%%:*}
    [ -n "${CFG[$k]:-}" ] || CFG[$k]=$(bamboost_default "$k")
    v=${CFG[$k]}
    if ! "${s##*:}" "$v" 2>/dev/null; then
      CFG[$k]=$(bamboost_default "$k")
      warn "$k is '$v' in the config, that can't be right: enter it again (Enter = the default)"
      bamboost_ask "$s"
    fi
  done
  say "The defaults suit most validators: RPC, hours, timer, log time zone, Telegram."
  if confirm "  Change the bamboost settings?"; then
    for s in $BAMBOOST_SETTINGS; do bamboost_ask "$s"; done
  fi
  [ -n "${CFG[BAMBOOST_TIMER_MINUTE]:-}" ] || CFG[BAMBOOST_TIMER_MINUTE]=$(( RANDOM % 60 ))
  [ -n "${CFG[BAMBOOST_CURRENT_AFTER_HOURS]:-}" ] || CFG[BAMBOOST_CURRENT_AFTER_HOURS]=$(( 10 + RANDOM % 7 ))
  say "A dry run only simulates what bamboost would send. Recommended for the first hours."
  if confirm "  Start as a dry run?"; then
    CFG[BAMBOOST_DRY_RUN]=1
  else
    CFG[BAMBOOST_DRY_RUN]=0
  fi
}
