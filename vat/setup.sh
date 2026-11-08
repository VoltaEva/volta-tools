#!/usr/bin/env bash
# volta-tools / vat: installer questions. Sourced by install.sh, which provides
# ask, confirm, say, warn, err, the check_* functions, CFG (config values) and the
# detected ID, VOTE, SOLANA, RPC_URL. The payout wallet is asked by install.sh itself.
# shellcheck disable=SC2154,SC2004  # CFG: an associative array, from install.sh

# default value of a vat setting, from module.env
vat_default(){ sed -n "s/^$1=//p" "$VOLTA_HOME/vat/module.env"; }

# the settings, each with the check of its answer
VAT_SETTINGS="VAT_PER_EPOCH:num VAT_LOW_EPOCHS:num VAT_RESERVE_EPOCHS:num VAT_RENT:num
  VAT_IDENTITY_MIN:num VAT_IDENTITY_FLOOR:num VAT_MIN_SWEEP:num
  VAT_TIMER_MINUTE:minute VAT_TIMER_JITTER:jitter VAT_TG:01"
# above these a value is unusual, maybe a typo: you are asked once more
VAT_USUAL_MAX="VAT_PER_EPOCH:5 VAT_LOW_EPOCHS:30 VAT_RESERVE_EPOCHS:30 VAT_RENT:1
  VAT_IDENTITY_MIN:100 VAT_IDENTITY_FLOOR:100 VAT_MIN_SWEEP:100"

# vat_ask NAME:check: one setting, with the value it has now as the default
vat_ask(){
  local name=${1%%:*} v shown=""
  [ -n "${CFG[$name]:-}" ] || [ "$name" != VAT_TIMER_MINUTE ] || shown=random
  ask v "  $name" "${CFG[$name]:-}" "check_${1##*:}" "$shown"
  CFG[$name]=$v
}
# vat_gt A B: is the number A above the number B?
vat_gt(){ awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

vat_setup(){
  local s k v big
  local -A kept=()
  # each value as it is now (from the config, or the default for an empty one) must pass
  # its check, or it is asked again
  for s in $VAT_SETTINGS; do
    k=${s%%:*}
    [ -n "${CFG[$k]:-}" ] || CFG[$k]=$(vat_default "$k")
    v=${CFG[$k]}
    if ! "check_${s##*:}" "$v" 2>/dev/null; then
      CFG[$k]=$(vat_default "$k")
      warn "$k is '$v' in the config, that can't be right: enter it again (Enter = the default)"
      vat_ask "$s"
    fi
  done
  say "The defaults suit most validators: reserve, limits, timer, Telegram."
  if confirm "  Change the vat settings?"; then
    for s in $VAT_SETTINGS; do vat_ask "$s"; done
  fi
  # the rules vat.sh checks too, and values far above the usual (a typo?)
  while true; do
    if vat_gt "${CFG[VAT_LOW_EPOCHS]}" "${CFG[VAT_RESERVE_EPOCHS]}"; then
      err "VAT_LOW_EPOCHS ${CFG[VAT_LOW_EPOCHS]} is above VAT_RESERVE_EPOCHS ${CFG[VAT_RESERVE_EPOCHS]}: a top-up starts below LOW and fills up to RESERVE"
      vat_ask VAT_LOW_EPOCHS:num; vat_ask VAT_RESERVE_EPOCHS:num; continue
    fi
    if vat_gt "${CFG[VAT_IDENTITY_FLOOR]}" "${CFG[VAT_IDENTITY_MIN]}"; then
      err "VAT_IDENTITY_FLOOR ${CFG[VAT_IDENTITY_FLOOR]} is above VAT_IDENTITY_MIN ${CFG[VAT_IDENTITY_MIN]}: a sweep leaves MIN, a top-up may go down to FLOOR"
      vat_ask VAT_IDENTITY_FLOOR:num; vat_ask VAT_IDENTITY_MIN:num; continue
    fi
    big=""
    for s in $VAT_USUAL_MAX; do
      k=${s%%:*}
      if [ "${kept[$k]:-}" != "${CFG[$k]}" ] && vat_gt "${CFG[$k]}" "${s##*:}"; then big=$k; break; fi
    done
    [ -n "$big" ] || break
    warn "$big ${CFG[$big]} is unusually large (the default is $(vat_default "$big")): a typo?"
    if confirm "  Keep $big at ${CFG[$big]}?"; then kept[$big]=${CFG[$big]}; else vat_ask "$big:num"; fi
  done
  [ -n "${CFG[VAT_TIMER_MINUTE]:-}" ] || CFG[VAT_TIMER_MINUTE]=$(( RANDOM % 60 ))
  say "A dry run only logs what vat would send. Recommended for the first hours."
  if confirm "  Start as a dry run?"; then
    CFG[VAT_DRY_RUN]=1
  else
    CFG[VAT_DRY_RUN]=0
  fi
}
