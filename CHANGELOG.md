# Changelog: volta-tools core

The core is `install.sh` and `lib/`. Each module has its own version and changelog:
[vat](vat/CHANGELOG.md), [bamboost](bamboost/CHANGELOG.md).

## 1.1.0 (2026-11-08)

- Versions per module: `<module>/VERSION`, and `VERSION` in the root for the core. The installer shows them.
- Payout wallets: the installer asks for the wallet of each enabled module that pays out. One is
  enough: a module whose wallet is empty pays out to another module's wallet, with a warning. None
  at all is an ERROR, and the installer asks again.
- Optional separate Telegram chat for alarms: `TG_CHAT_ALARM` (empty = `TG_CHAT_ID`).
- A friendlier installer: what's ahead and what to have ready, numbered steps, colors (questions in
  green, NO WARRANTY in red, warnings and errors), the balance of each payout wallet shown back.
  It starts with the disclaimer and asks you to accept it. `NO_COLOR=1` turns the colors off.
- Kinder input: arrow keys and Backspace work while typing, pasted junk is cleaned up (bracketed-paste
  marks, Windows line ends, quotes, spaces, invisible characters), a wrong y/n answer says why, and a
  wallet with a typo gets a clear reason (a wrong length, characters an address never has, not on-chain).
- The last 5 versions of the config are kept as `.env.bak-<time>`.
- The config is read as data, never run as shell: no line in it can run a command. Values with
  spaces or special characters (an RPC URL with `?api-key=`) are written in quotes, lines of your own
  are kept as you wrote them, and Windows line ends or spaces after a value no longer matter.
- No input (Ctrl+D, or the end of piped answers) stops the installer at any question. It never
  counts as an answer, so it can't switch a module out of its dry run.
- Settings are checked before the config is written: values that don't fit together, unusually large
  values (asked once more), and wrong values already in the config.
- A module you don't enable keeps its timer: the installer says so and gives the command to turn it
  off. The closing hints follow what this run did.
- On a terminal: a key typed on a non-Latin layout gets a hint, the line end of a pasted line can't
  answer the next question, Tab doesn't list files, and Ctrl+C just before a question stops at once.
- `-` empties any optional value (for a random timer minute, say).
- The query of an RPC URL (an API key) is hidden in messages and in the config view.
- volta-tools and its config must sit on a path without spaces: systemd takes the path as it is.
- Docs in Russian too (`README.ru.md` next to each README; English stays the main one), and
  `AGENTS.md`: the rules for AI coding agents that change this code.

## 1.0.0 (2026-11-07)

- Installer: finds the validator unit, identity keypair, vote account, ledger and RPC,
  asks only for the payout wallet and Telegram, shows the config before writing it.
  Run it again to change settings.
- One config for all modules (`.env`), built from each module's section.
- Optional Telegram, one bot for all modules.
- First module: vat 1.0.0.
