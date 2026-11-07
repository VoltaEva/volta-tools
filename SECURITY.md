# Security

These scripts move SOL, so this is exactly what they touch:

- `vat` signs with the identity keypair, the same file your validator already uses.
  It sends only from the identity, and only to your vote account and to `VAT_PAYOUT_WALLET`.
- The withdraw authority is never needed. Keep it off the server.
- The config holds addresses and file paths, never private keys. It is chmod 600
  because it may hold your Telegram bot token.
- No telemetry. Network calls go only to the RPC you configure and, if you set a bot, to Telegram.
  The bot token is passed to curl through stdin, never on the command line.
- No memo or any other marker in transactions.

Found a problem? Please report it privately: Security tab, "Report a vulnerability".
Don't open a public issue for it.
