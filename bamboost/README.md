# bamboost

**English** | [Русский](README.ru.md)

Validators that run Jito's BAM earn a BAM Boost (JIP-31) every epoch, paid in JitoSOL. It doesn't come
by itself: it has to be claimed, and an epoch that is not claimed within 20 epochs is clawed back by Jito.

`bamboost` runs once an hour and does two things:

1. **Claim.** For every epoch that is still open, it takes the epoch's reward tree from Jito's public
   bucket, computes the proof itself and checks the tree root against the epoch's on-chain merkle
   distributor: no match, no claim. The boost lands on the identity's JitoSOL account (the program
   pays only there). Older open epochs are claimed at once, the current one
   `BAMBOOST_CURRENT_AFTER_HOURS` after it starts.
2. **Payout.** It moves all the JitoSOL from the identity's JitoSOL account to
   `BAMBOOST_PAYOUT_WALLET` (empty: to the other module's wallet, see
   [payout wallets](../README.md#payout-wallets)). The wallet's JitoSOL account is created by the first
   payout; the identity pays for it.

Python 3 standard library only: the signing, the transactions and the proofs are done in the
script itself, there is nothing to install.

## What keeps it safe

- It never runs, not even a dry run, without an explicit payout wallet (`BAMBOOST_PAYOUT_WALLET` or,
  if that is empty, another module's payout wallet, with a warning). Only a live wallet: it must exist on-chain as a regular wallet, it can't be
  the identity or the vote account, and its key must be yours, kept off the server. Not an exchange
  deposit address: the payout is JitoSOL, a token.
- Before anything else it checks on-chain that the keypair is the identity of your vote account.
- It signs with the identity keypair only. It sends nothing but claims to the BAM Boost program and
  the payout to your wallet's JitoSOL account.
- It acts as the voting node only where the local validator runs with the real identity right now.
  A failover spare does nothing, except as insurance: an epoch that stays unclaimed for
  `BAMBOOST_BACKUP_AFTER` epochs (the voting node is up, but its timer is broken) is claimed by the
  spare, and the spare pays out only what it claimed itself.
- It stops when the identity holds less than 0.05 SOL.
- Temporary failures are retried (3 tries, 10 s apart); before every retry it checks whether the
  earlier try landed. Running it again is always safe: an epoch can be claimed only once.
- Dry run by default (`BAMBOOST_DRY_RUN=1`): it signs and simulates every transaction and sends nothing.

## What it costs

- About 0.0009 SOL per claimed epoch: the rent of the claim record (ClaimStatus). It is not
  refundable, the program has no instruction to close it.
- Once: about 0.0015 SOL for the identity's JitoSOL account, and the same for your wallet's on the
  first payout. That is rent and it stays on those accounts.
- The transaction fees.

## Setup

Run the [installer](../README.md#install) and enable bamboost when it asks. It uses the identity
keypair, the vote account and the payout wallet the installer has already found or asked for.
Then look at a dry run:

```bash
~/volta-tools/bamboost/bamboost.py                 # what it would claim and pay out now
~/volta-tools/bamboost/bamboost.py --auto --dry    # the same with the timer's logic
```

Each open epoch gets a line: `already claimed`, `OK (simulated ...)` with the amount, or the reason it
is skipped. When the dry run looks right, set `BAMBOOST_DRY_RUN=0` in `~/volta-tools/.env` and start
the timer:

```bash
sudo systemctl enable --now volta-bamboost.timer
```

## Manual runs

```bash
bamboost.py --live                  # claim the open epochs, then pay out
bamboost.py --live --no-sweep       # claim only
bamboost.py --sweep-only --live     # payout only
bamboost.py --from 1070 --to 1075   # only these epochs (a dry run without --live)
bamboost.py --tg-test               # a test message to the info chat and the alarm chat
```

`--live` needs `BAMBOOST_DRY_RUN=0`. Without `--live` (or `--auto`) every run is a dry run.

## Settings

All in `~/volta-tools/.env`, section `bamboost`. They are read on every run.

| variable | default | meaning |
|---|---|---|
| `BAMBOOST_PAYOUT_WALLET` | (asked) | where the JitoSOL goes; empty = another module's payout wallet, with a warning |
| `BAMBOOST_RPC_URL` | public mainnet RPC | RPC for the claims and the payout; a validator's own RPC works only with `--full-rpc-api` |
| `BAMBOOST_CURRENT_AFTER_HOURS` | random 10..16 | the current epoch is claimed this many hours after it starts |
| `BAMBOOST_BACKUP_AFTER` | `10` | a spare claims only epochs left unclaimed for this many epochs |
| `BAMBOOST_TIMER_MINUTE` | random | minute of the hour for the timer |
| `BAMBOOST_TIMER_JITTER` | `15min` | random extra delay for each run |
| `BAMBOOST_LOG_TZ` | server time | time zone of the log, like `Asia/Tokyo` |
| `BAMBOOST_TG` | `1` | Telegram messages from bamboost: `1` on, `0` off |
| `BAMBOOST_DRY_RUN` | `1` | `1` = simulate only, `0` = send |

It also reads `IDENTITY_KEYPAIR`, `VOTE_ACCOUNT`, `RPC_URL`, `VALIDATOR_BIN`, `LEDGER_DIR` and the
Telegram settings from the top of the file. After changing `BAMBOOST_TIMER_*`, run the installer again
so the timer gets the new time.

## Logs and messages

```bash
journalctl -u volta-bamboost -o cat
systemctl list-timers volta-bamboost.timer
cat ~/volta-tools/.state/bamboost.log
```

The timer prints only when it did something. `.state/bamboost.log` keeps only real actions: one line
per claim and payout, or a line with the reason when something failed; the same line is not written
again while it is among the last 30. A WARNING comes when an unclaimed epoch has 3 epochs or fewer
left. What goes into the log goes to Telegram: claims and payouts to `TG_CHAT_ID`; failures,
warnings and stops to `TG_CHAT_ALARM`.

## Failover pairs

Install on both nodes with the same answers. The node that votes with the real identity claims and
pays out; the spare only watches for epochs that stay unclaimed too long. After a switchover the
other node takes over on its next run.

## Remove

```bash
sudo systemctl disable --now volta-bamboost.timer
sudo rm /etc/systemd/system/volta-bamboost.service /etc/systemd/system/volta-bamboost.timer
sudo systemctl daemon-reload
```

## Disclaimer

No warranty. bamboost signs transactions with your identity keypair and moves real money: you run it
at your own risk. The author accepts no claims and no liability for any loss, whether it comes from a
bug, from the author's mistake or from yours. Non-commercial project. See the
[disclaimer](../README.md#disclaimer) and the [license](../LICENSE).
