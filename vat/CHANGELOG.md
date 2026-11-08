# Changelog: vat

## 1.1.0 (2026-11-08)

- If `VAT_PAYOUT_WALLET` is empty, vat pays out to another module's payout wallet
  (`BAMBOOST_PAYOUT_WALLET`) and warns about it on every run. With none at all it stops with an ERROR.
- Problems go to the alarm chat (`TG_CHAT_ALARM`) when one is set.
- The installer checks the settings together: `VAT_LOW_EPOCHS` above `VAT_RESERVE_EPOCHS`, or
  `VAT_IDENTITY_FLOOR` above `VAT_IDENTITY_MIN`, is asked again before the config is written, and an
  unusually large value is asked about once more.
- The config is read as data (core 1.1.0); the query of an RPC URL is hidden in the messages.
- Needs volta-tools core 1.1.0.

## 1.0.0 (2026-11-07)

- Vote account top-up for Alpenglow VAT, sweep of spare identity SOL to a payout wallet.
- Acts only on the node that votes with the real identity, refuses to run without an explicit
  payout wallet that exists on-chain, dry run by default.
