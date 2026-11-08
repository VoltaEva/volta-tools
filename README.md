# volta-tools

**English** | [Русский](README.ru.md)

Tools I run on my own Solana validators, cleaned up so anyone can use them.
Plain bash and Python (standard library only), systemd and the stock `solana` CLI. Nothing to build.

## Coming next

In testing now on my own nodes: a big block with a validator installer, a system optimizer, AF_XDP
setup and the rest of what I run my validators with. It joins as more modules of the same installer.

## Ready for production

| module | version | what it does |
|---|---|---|
| [vat](vat/) | 1.1.0 | keeps the vote account funded for Alpenglow VAT and sends spare SOL from the identity to your wallet |
| [bamboost](bamboost/) | 1.1.0 | claims the Jito BAM Boost (JIP-31) of every open epoch and pays the JitoSOL out to your wallet |

volta-tools is modular: one installer, one config, and the modules you pick. Every module has its own
version, changelog and README: what it does, how it works, how to use it.

## Install

```bash
git clone https://github.com/VoltaEva/volta-tools ~/volta-tools
sudo ~/volta-tools/install.sh
```

The installer finds your validator's unit, identity keypair, vote account, ledger and RPC by itself.
It asks only what it can't know: the payout wallets, and a Telegram bot if you want messages.
Then it asks which modules to enable. It shows the config before writing it to `~/volta-tools/.env`
(chmod 600, ignored by git) and installs the systemd timers of the modules you pick. It starts nothing:

```bash
sudo systemctl enable --now volta-vat.timer volta-bamboost.timer
```

Run the installer again any time to change settings: the current values are the defaults,
and you see every change before it is written. The last 5 versions of the config are kept as
`.env.bak-<time>`. On a failover pair, install on both nodes. Colors show only on a terminal;
`NO_COLOR=1` turns them off.

The config is plain `KEY=value` lines, read as data and never run as a script: a value with spaces or
special characters is written in quotes, and lines of your own are kept as you wrote them. The
installer never starts or stops a timer: if a module you don't enable has one, it tells you so and
gives the command to turn it off.

## Payout wallets

Each module that pays out has its own wallet: `VAT_PAYOUT_WALLET` and `BAMBOOST_PAYOUT_WALLET`.
The installer asks for them: give a wallet for each module, or only one. A module whose wallet is
empty then pays out to the wallet of the other one, and warns about it. With no payout wallet at
all nothing runs: you get an ERROR, and the installer asks again.

Only a live wallet:

- it already exists on-chain, so it is not empty: send it a little SOL first;
- you control it with your own key, kept off the validator server;
- not an exchange deposit address: bamboost pays out JitoSOL, a token that such an address may not accept;
- not the identity, not the vote account.

Any regular wallet works: a wallet app (Phantom, Solflare, Backpack), a hardware wallet behind one of
them (Ledger), or a multisig vault (Squads). A hardware wallet or a multisig is the safest choice: the
payouts then never depend on a key that sits on a computer.

The tools check what they can: the wallet must exist on-chain as a regular wallet and can't be the
identity or the vote account, or the module refuses to run. That you hold its key is the one thing
they can't check.

## Telegram

Optional, one bot for all modules. Transfers and payouts go to `TG_CHAT_ID`. Errors and alarms go to
`TG_CHAT_ALARM` if you set it, otherwise to the same chat. A problem is not repeated while it stays
the same. Each module can turn its messages off: `VAT_TG=0`, `BAMBOOST_TG=0`.

## Versions and updates

The core (the installer and `lib/`) and every module have their own version: `VERSION` in the root,
`<module>/VERSION`, with a changelog next to it.

```bash
~/volta-tools/vat/vat.sh --version
~/volta-tools/bamboost/bamboost.py --version
```

Update:

```bash
cd ~/volta-tools && git pull && sudo ./install.sh
```

Your `.env` stays as it is, new settings get their defaults.

## Requirements

- Agave or Jito-Agave validator under systemd
- `solana` CLI on the server (it comes with the validator install)
- bash, curl, awk, flock; python3 for bamboost
- bamboost: mainnet

## AI coding agents

[AGENTS.md](AGENTS.md) has the rules for changing this code, for agents and people alike.

## Disclaimer

This is a non-commercial project: I share these tools for free, as they are. There is no warranty
of any kind. They move real money, and you run them at your own risk. I accept no claims and no
liability, financial or any other, for any loss or damage, whether it comes from a bug in the
tools, from a mistake of mine, or from a mistake of the user (a wrong wallet, a wrong setting,
a wrong key). Start with a dry run, read what the tool is going to do, and only then let it send.
The [license](LICENSE) says the same in legal terms ("No Liability").

## License

[PolyForm Internal Use 1.0.0](LICENSE). Use it and change it for running your own validators, free of charge.
Don't redistribute or sell it, as is or modified. For anything else, open an issue and ask.
