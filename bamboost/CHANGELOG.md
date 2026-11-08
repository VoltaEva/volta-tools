# Changelog: bamboost

## 1.1.0 (2026-11-08)

- First release in volta-tools. Claims the Jito BAM Boost (JIP-31) of every open epoch to the
  identity and pays the JitoSOL out to the payout wallet.
- The reward tree comes from Jito's bucket, the proof is computed locally, and the tree root must
  match the on-chain distributor. Retries for temporary failures, a log without repeats, Telegram.
- On a failover spare it only claims epochs left unclaimed for `BAMBOOST_BACKUP_AFTER` epochs.
- Settings from the volta-tools config. Pays out to `BAMBOOST_PAYOUT_WALLET` or, if that is empty, to
  another module's payout wallet (`VAT_PAYOUT_WALLET`), with a warning. Refuses to run without any
  payout wallet, with one that does not exist on-chain as a regular wallet, or when the keypair is not
  the identity of the vote account.
- Hourly systemd timer, dry run by default.
- `BAMBOOST_RPC_URL` may have a query, like `?api-key=...`. The config is read the same way as the core
  reads it: values in quotes, never run.
- Needs volta-tools core 1.1.0 and python3.
