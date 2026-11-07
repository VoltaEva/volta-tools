# Changelog

## 1.0.0 (2026-11-07)

- Installer: finds the validator unit, identity keypair, vote account, ledger and RPC,
  asks only for the payout wallet and Telegram, shows the config before writing it.
  Run it again to change settings.
- One config for all modules (`.env`), built from each module's section.
- Optional Telegram, one bot for all modules.
- vat 1.0.0: vote account top-up for Alpenglow VAT, sweep of spare identity SOL to a payout wallet.
  Acts only on the node that votes with the real identity, refuses to run without an explicit payout
  wallet that exists on-chain, dry run by default.
