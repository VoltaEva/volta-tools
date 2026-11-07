#!/usr/bin/env bash
# volta-tools / vat: installer questions. Sourced by install.sh, which provides
# ask, confirm, CFG (config values) and the detected ID, VOTE, SOLANA, RPC_URL.
# shellcheck disable=SC2154  # CFG comes from install.sh

vat_check_payout(){
  local p
  p=$(payout_problem "$1")
  [ -z "$p" ] && return 0
  echo "  $p" >&2
  return 1
}
vat_check_num(){
  [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]] && return 0
  echo "  a number, like 3 or 0.83" >&2; return 1
}
vat_check_minute(){
  if [ -z "$1" ]; then return 0; fi
  if [[ $1 =~ ^[0-9]{1,2}$ ]] && (( 10#$1 < 60 )); then return 0; fi
  echo "  0..59, or empty for a random minute" >&2; return 1
}
vat_check_jitter(){
  [[ $1 =~ ^[0-9]+(s|sec|m|min|h)?$ ]] && return 0
  echo "  like 900 or 15min" >&2; return 1
}
vat_check_01(){
  [[ $1 =~ ^[01]$ ]] && return 0
  echo "  0 or 1" >&2; return 1
}
# default value of a vat setting, from module.env
vat_default(){ sed -n "s/^$1=//p" "$VOLTA_HOME/vat/module.env"; }

vat_setup(){
  local v k name
  echo "  Payout wallet: where spare identity SOL goes. Required, it must already exist"
  echo "  on-chain, and its keys must NOT be on this server."
  ask v "  payout wallet" "${CFG[VAT_PAYOUT_WALLET]:-}" vat_check_payout
  CFG[VAT_PAYOUT_WALLET]=$v
  if confirm "  change the other vat settings (reserve, limits, timer, Telegram)?"; then
    for k in VAT_PER_EPOCH:num VAT_LOW_EPOCHS:num VAT_RESERVE_EPOCHS:num VAT_RENT:num \
             VAT_IDENTITY_MIN:num VAT_IDENTITY_FLOOR:num VAT_MIN_SWEEP:num \
             VAT_TIMER_MINUTE:minute VAT_TIMER_JITTER:jitter VAT_TG:01; do
      name=${k%%:*}
      ask v "  $name" "${CFG[$name]:-$(vat_default "$name")}" "vat_check_${k##*:}"
      # shellcheck disable=SC2004  # CFG is an associative array (install.sh)
      CFG[$name]=$v
    done
  fi
  [ -n "${CFG[VAT_TIMER_MINUTE]:-}" ] || CFG[VAT_TIMER_MINUTE]=$(( RANDOM % 60 ))
  if confirm "  start with a dry run (only logs, sends nothing)? Recommended for the first hours"; then
    CFG[VAT_DRY_RUN]=1
  else
    CFG[VAT_DRY_RUN]=0
  fi
}
