# vat

**English** | [Русский](README.ru.md)

Under Alpenglow the vote account pays VAT every epoch (0.8 SOL on mainnet), while block revenue lands on the identity.
Leave it alone and the vote account runs dry, while the identity piles up SOL on a hot server.

`vat` runs once an hour and does two things:

1. **Top-up.** When the vote account holds VAT for fewer than `VAT_LOW_EPOCHS` epochs, it sends SOL from the identity
   to fill it up to `VAT_RESERVE_EPOCHS`. The identity never goes below `VAT_IDENTITY_FLOOR` for this.
2. **Sweep.** Everything on the identity above `VAT_IDENTITY_MIN` goes to `VAT_PAYOUT_WALLET`, if it is at least `VAT_MIN_SWEEP`
   (empty: to the other module's wallet, see [payout wallets](../README.md#payout-wallets)).

## What keeps it safe

- It never runs, not even a dry run, without an explicit payout wallet: `VAT_PAYOUT_WALLET` or, if that is
  empty, another module's payout wallet (then it warns on every run). Only a live wallet: it must already
  exist on-chain as a regular wallet, so a typo in the address can't swallow SOL, and its key must be yours,
  kept off the server.
- It signs with the identity keypair only. The withdraw authority is never needed, keep it off the server.
- It acts only on the node that votes with the real identity right now: it asks the local validator
  (`agave-validator contact-info`). A failover spare running another identity does nothing,
  so you can install vat on both nodes of a pair.
- Before sending anything it checks on-chain that the vote account belongs to that identity.
- Dry run by default (`VAT_DRY_RUN=1`): it only logs what it would send.
- One run at a time.

## Setup

Run the [installer](../README.md#install) and enable vat when it asks. It finds the identity keypair,
the vote account and the ledger in your validator's systemd unit (or the start script the unit runs)
and asks for the payout wallet.

Look at a dry run before you set `VAT_DRY_RUN=0`:

```
$ ~/volta-tools/vat/vat.sh --dry-run
2026-11-07T19:41:07Z vat 1.1.0 dry=1 | identity 7xKq3m 5.214000000 (keeps 3) | vote 9fPa2c 2.410000000 (top-up below 2.520000000 to 4.180000000) | payout Hs8dQv
2026-11-07T19:41:07Z vote top-up: 1.770000000
2026-11-07T19:41:07Z DRY: would send 1.770000000 SOL to <your vote account>
2026-11-07T19:41:07Z spare 0.443990000 is below VAT_MIN_SWEEP 1, nothing to sweep
```

## Settings

All in `~/volta-tools/.env`, section `vat`. They are read on every run.

| variable | default | meaning |
|---|---|---|
| `VAT_PAYOUT_WALLET` | (asked) | where spare identity SOL goes; empty = another module's payout wallet, with a warning |
| `VAT_PER_EPOCH` | `0.83` | VAT per epoch with a small margin |
| `VAT_LOW_EPOCHS` | `3` | top up when the vote account covers fewer epochs than this |
| `VAT_RESERVE_EPOCHS` | `5` | fill the vote account up to this many epochs |
| `VAT_RENT` | `0.03` | rent-exempt minimum of the vote account, kept on top |
| `VAT_IDENTITY_MIN` | `3` | the identity keeps this after a sweep |
| `VAT_IDENTITY_FLOOR` | `1` | a top-up never takes the identity below this |
| `VAT_MIN_SWEEP` | `1` | smaller amounts are not swept |
| `VAT_TIMER_MINUTE` | random | minute of the hour for the timer |
| `VAT_TIMER_JITTER` | `15min` | random extra delay for each run |
| `VAT_TG` | `1` | Telegram messages from vat: `1` on, `0` off |
| `VAT_DRY_RUN` | `1` | `1` = log only, `0` = send |

After changing `VAT_TIMER_*`, run the installer again so the timer gets the new time.

## Logs

```bash
journalctl -u volta-vat -o cat
systemctl list-timers volta-vat.timer
```

## Failover pairs

Install on both nodes with the same answers. The spare logs `not the voting node ..., skip` every hour.
After a switchover the other node takes over on its next run.

## Remove

```bash
sudo systemctl disable --now volta-vat.timer
sudo rm /etc/systemd/system/volta-vat.service /etc/systemd/system/volta-vat.timer
sudo systemctl daemon-reload
```

## Disclaimer

No warranty. vat signs transfers with your identity keypair and moves real money: you run it at your
own risk. The author accepts no claims and no liability for any loss, whether it comes from a bug,
from the author's mistake or from yours. Non-commercial project. See the
[disclaimer](../README.md#disclaimer) and the [license](../LICENSE).
