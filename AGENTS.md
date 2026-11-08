# AGENTS.md

Rules for AI coding agents, and for people, who change this code. Read it before the first edit.

## What this is

volta-tools moves a Solana validator's real money (SOL, JitoSOL) on a timer. A mistake here loses
someone's funds, so plain code that is easy to check beats clever code.

- `install.sh`: the one installer. Seven steps: it finds the validator, asks only what it can't find,
  writes one config (`.env`), installs the timers of the modules you pick, and starts nothing.
- `lib/common.sh`: shared helpers: the config (read and write), questions, payout wallet checks,
  Telegram, the state of a module's timer. `lib/common.env`: the top of the config template.
- Modules, one folder each (`vat/`, `bamboost/`), all with the same contract:
  - `module.env`: the module's config section. Its first comment is `# about: ...` (the installer
    shows it). A module that pays out has `<MODULE>_PAYOUT_WALLET`;
  - `setup.sh`: `<module>_setup`, the module's questions (install.sh sources it);
  - `install.sh`: a dry run, then `/etc/systemd/system/volta-<module>.service` and `.timer`. Run by
    install.sh it exits 0 when it wrote them and 3 when the user said no;
  - the tool itself, `VERSION`, `CHANGELOG.md`, `README.md` and `README.ru.md`.
- A new module is a new folder with that contract: install.sh finds it by its `module.env`.

## Hard rules

1. The config is data, never code. Never `source`, `.` or `eval` the `.env`. Read it with `load_env`
   or `env_line` (bash) and `read_kv` (Python): both follow the same rules, keep them in step. Write
   values with `env_quote`. Lines the user added are kept as written.
2. Dry run first, and by default: `<MODULE>_DRY_RUN=1`. Nothing that sends a transaction runs in tests,
   CI or examples. Never run a `--live` command or set a `*_DRY_RUN` to 0 unless the human asked for
   exactly that.
3. Payouts go only to a live wallet: it exists on-chain, its owner is the System Program, and it is not
   the identity or the vote account (`payout_problem`). Never weaken these checks.
4. Keys and secrets: never print, log, copy or commit a keypair, a seed phrase or a bot token. Sign with
   the identity keypair only; the withdraw authority never belongs on the server. The Telegram token
   goes to curl through stdin, never on a command line.
5. The installers never start, stop, restart, enable or disable a service or a timer. They write unit
   files, run `systemctl daemon-reload`, and print the commands for the human.
6. Questions go through `confirm` and `ask`: a y/n question loops until it gets y or n, and no input
   (EOF, Ctrl+D) stops everything, never counting as an answer. Pasted input goes through `clean_input`.
7. A module acts only on the node that votes with the real identity right now, so it can run on both
   nodes of a failover pair.
8. No silent changes: every change a user can notice goes into the module's `CHANGELOG.md` and bumps
   only that module's `VERSION` (for the installer and `lib/`: `VERSION` and `CHANGELOG.md` in the root).

## Style

- bash with `set -euo pipefail`, clean under shellcheck (`.shellcheckrc`). Python 3, standard library
  only, clean under pyflakes. No new dependencies.
- English in code, messages and the main docs. A `README.ru.md` is the Russian version of the README
  next to it: change both. Short, plain sentences.
- Messages for people: `say`, `ok`, `warn`, `err`, `hint`, `die`. Colors only through the `C_*`
  variables (empty when there is no terminal); inside a readline prompt, the `R_*` ones.
- Keep the disclaimer in the script headers and the READMEs.
- Nothing personal in the repo: no real addresses, IP addresses, host names or names.

## Before a change is done

```bash
bash -n install.sh lib/common.sh */*.sh
shellcheck -x install.sh lib/common.sh */*.sh
python3 -m pyflakes bamboost/bamboost.py
```

Then dry runs on a test validator: `sudo ./install.sh` (answer `n` at the timers),
`vat/vat.sh --dry-run`, `bamboost/bamboost.py --auto --dry`.
