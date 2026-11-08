# Security

These scripts move SOL, so this is exactly what they touch:

- `vat` signs with the identity keypair, the same file your validator already uses.
  It sends only from the identity, and only to your vote account and to your payout wallet.
- `bamboost` signs with the identity keypair too. It sends claims to Jito's BAM Boost program, which
  pays into the identity's own JitoSOL account, and the payout of that JitoSOL to your payout wallet.
- The withdraw authority is never needed. Keep it off the server.
- The config holds addresses and file paths, never private keys. It is chmod 600
  because it may hold your Telegram bot token.
- No telemetry. Network calls go only to the RPC you configure, to Jito's public reward-tree bucket
  (bamboost) and, if you set a bot, to Telegram. The bot token never appears on a command line.
- No memo or any other marker in transactions.

Found a problem? Please report it privately: Security tab, "Report a vulnerability".
Don't open a public issue for it.
