# volta-tools

Tools I run on my own Solana validators, cleaned up so anyone can use them.
Plain bash, systemd and the stock `solana` CLI. Nothing to build.

| module | what it does |
|---|---|
| [vat](vat/) | keeps the vote account funded for Alpenglow VAT and sends spare SOL from the identity to your wallet |

## Install

```bash
git clone https://github.com/VoltaEva/volta-tools ~/volta-tools
sudo ~/volta-tools/install.sh
```

The installer finds your validator's unit, identity keypair, vote account, ledger and RPC by itself.
It asks only what it can't know: the payout wallet, and a Telegram bot if you want messages.
It shows the config before writing it to `~/volta-tools/.env` (chmod 600, ignored by git)
and installs the systemd timers of the modules you pick. It starts nothing:

```bash
sudo systemctl enable --now volta-vat.timer
```

Run the installer again any time to change settings: the current values are the defaults,
and you see every change before it is written. On a failover pair, install on both nodes.

## Telegram

Optional, one bot for all modules. vat reports every transfer it makes. A problem is reported once,
again only if it changes, and then "OK again" when it is gone. A dry run reports problems only.
`VAT_TG=0` turns vat's messages off.

## Update

```bash
cd ~/volta-tools && git pull && sudo ./install.sh
```

Your `.env` stays as it is, new settings get their defaults.

## Requirements

- Agave or Jito-Agave validator under systemd
- `solana` CLI on the server (it comes with the validator install)
- bash, curl, awk, flock

## License

[PolyForm Internal Use 1.0.0](LICENSE). Use it and change it for running your own validators, free of charge.
Don't redistribute or sell it, as is or modified. For anything else, open an issue and ask.
