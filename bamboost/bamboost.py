#!/usr/bin/env python3
# volta-tools / bamboost
#
# Jito BAM Boost (JIP-31): claims the boost of every open epoch to the identity, then pays the
# JitoSOL out to your payout wallet. Settings come from the volta-tools config (.env) that
# install.sh writes. Python 3 standard library only: nothing to build or install.
#
#   bamboost.py                         dry run: signs and simulates the claims and the payout, sends nothing
#   bamboost.py --live                  claim the open epochs, then pay the JitoSOL out
#   bamboost.py --live --no-sweep       claim only
#   bamboost.py --sweep-only [--live]   payout only
#   bamboost.py --auto                  timer mode (below); prints nothing when there is nothing to do
#   bamboost.py --auto --dry            the timer's logic, simulation only, with details
#   bamboost.py --tg-test               a test message to the info chat and to the alarm chat
# More: --from/--to EPOCH, --rpc URL, --key PATH, --version, --close (manual only: close the
# JitoSOL account of the identity after the payout).
# BAMBOOST_DRY_RUN=1 in the config (the default) makes every run a dry run.
#
# --auto, on the node that votes with the identity right now: older open epochs are claimed at
#   once, the current one not before BAMBOOST_CURRENT_AFTER_HOURS from its start, then the JitoSOL
#   is paid out. On a spare node of a failover pair it is insurance only: it claims epochs left
#   unclaimed for BAMBOOST_BACKUP_AFTER epochs or more (the voting node is up, but its timer or
#   script is broken) and pays out only what it claimed itself.
# Retries: temporary failures (RPC, BlockhashNotFound, not confirmed) get up to 3 tries 10 s apart,
#   with an "already done?" check before each retry; final errors are not retried. Then the next
#   timer run (hourly) tries again.
# Log: .state/bamboost.log, real actions only (--live, --auto). One line per epoch when all is well,
#   a line with the reason when not (the same line is not written again while it is among the
#   last 30), a WARNING when an unclaimed epoch has 3 epochs or fewer left. Over 1 MB it moves to
#   bamboost.log.1 (one old copy).
# Telegram (TG_BOT_TOKEN, TG_CHAT_ID, TG_CHAT_ALARM): the summary goes to the info chat; failures,
#   warnings, stops and crashes go to the alarm chat. Only what went into the log is sent, so a
#   repeat that the log drops is not sent either.
#
# The reward tree comes from Jito's GCS bucket (as in the official jito-bam-boost-cli); the proof
# is computed here, and the tree root must match the epoch's on-chain merkle distributor, or there
# is no claim. The claim goes to the JitoSOL ATA of the identity (the program wants owner ==
# claimant). The payout is a separate transaction: the ATA of the wallet (created when missing,
# the identity pays) gets all of it, and the ATA of the identity stays open with zero.
# The claim record (ClaimStatus) rent is not refundable: the program has no instruction to close
# it. Epoch E can be claimed up to E+19; in E+20 Jito claws it back. Running it again is safe.
#
# No warranty: you run it at your own risk. See README.md (Disclaimer) and LICENSE.

import argparse, base64, datetime, hashlib, json, os, re, socket, struct, subprocess, sys, time
import urllib.parse, urllib.request

HERE = os.path.dirname(os.path.realpath(__file__))
VOLTA_HOME = os.path.dirname(HERE)
ENV_PATH = os.environ.get("VOLTA_ENV") or os.path.join(VOLTA_HOME, ".env")
LOG_PATH = os.path.join(VOLTA_HOME, ".state", "bamboost.log")
LOG_MAX = 1 << 20          # 1 MB, then -> bamboost.log.1


def _version():
    try:
        with open(os.path.join(HERE, "VERSION"), encoding="utf-8") as f:
            return f.read().strip() or "unknown"
    except OSError:
        return "unknown"


VERSION = _version()
RPC_DEFAULT = "https://api.mainnet-beta.solana.com"
LOCAL_RPC = "http://127.0.0.1:8899"
GCS = "https://storage.googleapis.com/jito-bam-boost/mainnet/{epoch}/merkle_tree.json"
WINDOW = 20                # epoch E can be claimed in epochs E..E+19
WARN_LEFT = 3              # WARNING when an unclaimed epoch has <= N epochs of its window left
TRIES, PAUSE = 3, 10       # temporary failures: tries, and seconds between them
TRANSIENT = ("BlockhashNotFound", "Blockhash not found", "Node is behind", "-32005", "-32004",
             "Too many requests", "429", "timed out", "Service unavailable")
HDR = {"User-Agent": "curl/8.5.0", "Content-Type": "application/json"}
SYSTEM_PROGRAM = "11111111111111111111111111111111"
VOTE_PROGRAM = "Vote111111111111111111111111111111111111111"
CONF = {}                  # the config, filled by load_conf()


B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58e(b):
    n = int.from_bytes(b, "big")
    s = ""
    while n:
        n, r = divmod(n, 58)
        s = B58[r] + s
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + s


def b58d(s, size=32):
    n = 0
    for c in s:
        n = n * 58 + B58.index(c)
    return n.to_bytes(size, "big")


PROG = b58d("BoostxbPp2ENYHGcTLYt1obpcY13HE4NojdqNWdzqSSb")
MINT = b58d("J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn")
TOKEN = b58d("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
ATAP = b58d("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")
SYSP = bytes(32)
CLAIM_DISC = bytes([62, 198, 214, 193, 213, 159, 108, 210])
DECIMALS = 9

# --- ed25519 (RFC 8032) ---------------------------------------------------
P = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, P - 2, P)) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _inv(x):
    return pow(x, P - 2, P)


def _add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % P
    b = (y1 + x1) * (y2 + x2) % P
    c = 2 * t1 * t2 * D % P
    d = 2 * z1 * z2 % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(s, p):
    q = (0, 1, 1, 0)
    while s:
        if s & 1:
            q = _add(q, p)
        p = _add(p, p)
        s >>= 1
    return q


def _recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * _inv(D * y * y + 1) % P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


_GY = 4 * _inv(5) % P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % P)


def _compress(p):
    zi = _inv(p[2])
    x, y = p[0] * zi % P, p[1] * zi % P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _expand(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def ed_pub(seed):
    return _compress(_mul(_expand(seed)[0], _G))


def ed_sign(seed, msg):
    a, prefix = _expand(seed)
    pub = _compress(_mul(a, _G))
    r = int.from_bytes(hashlib.sha512(prefix + msg).digest(), "little") % L
    rb = _compress(_mul(r, _G))
    k = int.from_bytes(hashlib.sha512(rb + pub + msg).digest(), "little") % L
    return rb + ((r + k * a) % L).to_bytes(32, "little")


# --- PDA / ATA -------------------------------------------------------------
def _on_curve(b):
    y = int.from_bytes(b, "little") & ((1 << 255) - 1)
    if y >= P:
        return False
    x2 = (y * y - 1) * _inv(D * y * y + 1) % P
    return x2 == 0 or pow(x2, (P - 1) // 2, P) == 1


def pda(seeds, prog):
    for bump in range(255, -1, -1):
        h = hashlib.sha256(b"".join(seeds) + bytes([bump]) + prog + b"ProgramDerivedAddress").digest()
        if not _on_curve(h):
            return h
    raise RuntimeError("no PDA found")


def ata(owner):
    return pda([owner, TOKEN, MINT], ATAP)


def distributor(epoch):
    return pda([b"merkle_distributor", MINT, epoch.to_bytes(8, "little")], PROG)


def claim_status(ident, dist):
    return pda([b"claim_status", ident, dist], PROG)


# --- network ---------------------------------------------------------------
def http_json(url, payload=None, timeout=30, tries=3):
    data = json.dumps(payload).encode() if payload is not None else None
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, data=data, headers=HDR)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)
        except Exception:
            if attempt == tries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def rpc(url, method, params, tries=4):
    for attempt in range(tries):
        try:
            r = http_json(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, tries=1)
        except Exception:
            if attempt == tries - 1:
                raise
            time.sleep(2 * (attempt + 1))
            continue
        if "error" in r:
            raise RuntimeError(json.dumps(r["error"], ensure_ascii=False))
        return r["result"]


def token_amount(url, addr_b58):
    acc = rpc(url, "getAccountInfo", [addr_b58, {"encoding": "base64", "commitment": "confirmed"}])["value"]
    if not acc:
        return None
    return int.from_bytes(base64.b64decode(acc["data"][0])[64:72], "little")


def epoch_age_h(url, ep):
    first = ep["absoluteSlot"] - ep["slotIndex"]
    try:
        s = rpc(url, "getBlocksWithLimit", [first, 1, {"commitment": "confirmed"}])[0]
        return (time.time() - rpc(url, "getBlockTime", [s])) / 3600
    except Exception:
        return ep["slotIndex"] * 0.212 / 3600


# --- reward tree -----------------------------------------------------------
def tree_proof(epoch, ident):
    """The tree of the epoch from GCS -> (amount, proof, root). Same scheme as the jito merkle-tree:
    leaf = sha256(0x00 || sha256(claimant || amount_le)), nodes sha256(0x01 || min || max)."""
    order, amounts = [], {}
    for x in http_json(GCS.format(epoch=epoch)):
        pk, amt = b58d(x["pubkey"]), int(x["amount"])
        if pk in amounts:
            amounts[pk] += amt
        else:
            amounts[pk] = amt
            order.append(pk)
    level = [hashlib.sha256(b"\x00" + hashlib.sha256(pk + amounts[pk].to_bytes(8, "little")).digest()).digest()
             for pk in order]
    levels = [level]
    while len(level) > 1:
        nxt = []
        for n in range(0, len(level), 2):
            l = level[n]
            r = level[n + 1] if n + 1 < len(level) else level[n]
            lo, hi = (l, r) if l <= r else (r, l)
            nxt.append(hashlib.sha256(b"\x01" + lo + hi).digest())
        levels.append(nxt)
        level = nxt
    root = level[0] if level else None
    if ident not in amounts:
        return 0, [], root
    idx, proof = order.index(ident), []
    for lvl in levels[:-1]:
        s = idx ^ 1
        proof.append(lvl[s] if s < len(lvl) else lvl[idx])
        idx //= 2
    return amounts[ident], proof, root


# --- transactions ------------------------------------------------------------
def cu16(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def compile_tx(seed, payer, writable, readonly, ixs, blockhash):
    keys = [payer] + writable + readonly
    i = {k: n for n, k in enumerate(keys)}
    body = b""
    for prog, accts, data in ixs:
        body += bytes([i[prog]]) + cu16(len(accts)) + bytes(i[x] for x in accts) + cu16(len(data)) + data
    msg = bytes([1, 0, len(readonly)]) + cu16(len(keys)) + b"".join(keys) + blockhash + cu16(len(ixs)) + body
    sig = ed_sign(seed, msg)
    return base64.b64encode(cu16(1) + sig + msg).decode(), b58e(sig)


def build_claim(seed, ident, epoch, amount, proof, bh):
    dist = distributor(epoch)
    vault, cstat, to = ata(dist), claim_status(ident, dist), ata(ident)
    data = CLAIM_DISC + struct.pack("<Q", amount) + struct.pack("<I", len(proof)) + b"".join(proof)
    ixs = [(ATAP, [ident, to, ident, MINT, SYSP, TOKEN], b"\x01"),
           (PROG, [dist, cstat, vault, to, ident, TOKEN, SYSP], data)]
    return compile_tx(seed, ident, [to, dist, cstat, vault], [SYSP, MINT, TOKEN, ATAP, PROG], ixs, bh)


def build_sweep(seed, ident, wallet, amount, bh, close=False):
    """Moves all JitoSOL from the ATA of the identity to the ATA of the wallet. CloseAccount only with close=True (manual)."""
    src, dst = ata(ident), ata(wallet)
    ixs = []
    if amount > 0:
        ixs += [(ATAP, [ident, dst, wallet, MINT, SYSP, TOKEN], b"\x01"),
                (TOKEN, [src, MINT, dst, ident], b"\x0c" + struct.pack("<Q", amount) + bytes([DECIMALS]))]
    if close:
        ixs.append((TOKEN, [src, ident, ident], b"\x09"))
    if amount > 0:
        return compile_tx(seed, ident, [src, dst], [wallet, SYSP, MINT, TOKEN, ATAP], ixs, bh)
    return compile_tx(seed, ident, [src], [TOKEN], ixs, bh)


def describe(err, logs):
    e = json.dumps(err)
    logs = logs or []
    if "6014" in e or any("ClaimExpired" in l for l in logs):
        return "window closed (ClaimExpired)"
    if any("already in use" in l for l in logs):
        return "already claimed (ClaimStatus exists)"
    if any("verification failure" in l.lower() for l in logs) or "SignatureFailure" in e:
        return "signature failed: wrong key"
    tail = [l for l in logs if "rror" in l][:1]
    return (e + " " + (tail[0][:160] if tail else "")).strip()


def wait(url, sig, timeout=75):
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(2)
        try:
            s = rpc(url, "getSignatureStatuses", [[sig], {"searchTransactionHistory": False}])["value"][0]
        except Exception:
            continue
        if s:
            if s.get("err"):
                return "ERROR " + json.dumps(s["err"])
            if s.get("confirmationStatus") in ("confirmed", "finalized"):
                return s["confirmationStatus"]
    return "not confirmed in 75 s"


def latest_bh(url):
    return b58d(rpc(url, "getLatestBlockhash", [{"commitment": "finalized"}])["value"]["blockhash"])


def transient(msg):
    """A temporary failure, worth a retry? Returns a short name of the cause, or None."""
    return next((t for t in TRANSIENT if t in msg), None)


def done_ok(st):
    """Status from send(): the goal is reached (maybe by another transaction or another node)."""
    return st in ("confirmed", "finalized") or st.startswith("already done") or "already claimed" in st


def send(url, build, already=None):
    """build(blockhash) -> (tx, sig); already() -> True if the goal is already reached (an earlier try landed).
    Temporary failures: up to TRIES tries PAUSE s apart, already() before each retry; final ones return at once."""
    last, sig = "", None
    for n in range(TRIES):
        if n:
            time.sleep(PAUSE)
            try:
                if already and already():
                    return "already done (an earlier try landed)", sig
            except Exception:
                pass
        try:
            tx, sig = build(latest_bh(url))
            rpc(url, "sendTransaction", [tx, {"encoding": "base64", "preflightCommitment": "confirmed", "maxRetries": 5}])
        except RuntimeError as ex:          # the RPC answered with an error, usually the preflight check
            t = transient(str(ex))
            if not t:
                return "rejected: " + describe(str(ex), [str(ex)]), sig
            last = t
            continue
        except Exception:                   # network / HTTP / timeout, after the retries inside rpc()
            last = "RPC not answering"
            continue
        st = wait(url, sig)
        if st.startswith("ERROR"):
            try:
                if already and already():
                    return "already done (by another transaction)", sig
            except Exception:
                pass
            return st, sig
        if st in ("confirmed", "finalized"):
            return st, sig
        last = st
    return "failed after %d tries: %s" % (TRIES, last), sig


def simulate(url, tx, addrs):
    return rpc(url, "simulateTransaction", [tx, {"encoding": "base64", "sigVerify": True, "commitment": "confirmed",
                                                 "accounts": {"addresses": addrs, "encoding": "base64"}}])["value"]


def post_token(acc):
    return int.from_bytes(base64.b64decode(acc["data"][0])[64:72], "little") / 1e9 if acc else 0.0


# --- config ------------------------------------------------------------------
def read_kv(path):
    """KEY=value lines of the config, never executed; read the same way as env_line in
    lib/common.sh: a bare value ends at a " #" comment, "double quotes" take backslash
    escapes of the quote, backslash, $ and backtick, 'single quotes' are taken as is,
    and a CR at the line end is dropped."""
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.rstrip("\r\n"))
                if not m:
                    continue
                k, r = m.group(1), m.group(2).lstrip()
                if r[:1] == '"':
                    v, i = [], 1
                    while i < len(r):
                        if r[i] == "\\" and i + 1 < len(r) and r[i + 1] in '"\\$`':
                            v.append(r[i + 1])
                            i += 2
                            continue
                        if r[i] == '"':
                            break
                        v.append(r[i])
                        i += 1
                    else:
                        v = [r]     # no closing quote: as written, for the checks to see
                    v = "".join(v)
                elif r[:1] == "'":
                    v = r[1:].split("'", 1)[0] if "'" in r[1:] else r
                else:
                    v = re.split(r"\s#", r, 1)[0].strip()
                out[k] = v
    except OSError:
        pass
    return out


def load_conf():
    if not os.path.isfile(ENV_PATH):
        sys.exit("no config at %s, run %s first" % (ENV_PATH, os.path.join(VOLTA_HOME, "install.sh")))
    CONF.clear()
    CONF.update(read_kv(ENV_PATH))


def conf_int(name, default, lo, hi):
    v = CONF.get(name) or str(default)
    if not re.fullmatch(r"\d+", v) or not lo <= int(v) <= hi:
        sys.exit("%s must be a whole number %d..%d, got '%s' (%s)" % (name, lo, hi, v, ENV_PATH))
    return int(v)


def conf_01(name, default):
    v = CONF.get(name) or default
    if v not in ("0", "1"):
        sys.exit("%s must be 0 or 1, got '%s' (%s)" % (name, v, ENV_PATH))
    return v == "1"


def is_addr(s):
    if not re.fullmatch(r"[1-9A-HJ-NP-Za-km-z]{32,44}", s or ""):
        return False
    try:
        b58d(s)
    except (ValueError, OverflowError):
        return False
    return True


def account(url, addr):
    return rpc(url, "getAccountInfo", [addr, {"encoding": "base64", "commitment": "confirmed"}])["value"]


def payout_problem(url, wallet, ident, vote):
    """Why an address can't be the payout wallet, or None. It must exist on-chain as a regular
    wallet, so a typo can never swallow the JitoSOL."""
    if " " in wallet:
        return "not an address: it has a space inside (two values pasted?)"
    bad = sorted(set(c for c in wallet if c not in B58))
    if bad:
        return "not an address: it has characters an address never has: %s" % "".join(c for c in bad if c.isprintable())
    if not 32 <= len(wallet) <= 44:
        return "not an address: %d characters, a Solana address has 32 to 44" % len(wallet)
    if not is_addr(wallet):
        return "not a valid address: check it for a typo (a missing or extra character)"
    if wallet in (ident, vote):
        return "it must be another wallet, not the identity or the vote account"
    acc = account(url, wallet)
    if not acc:
        return "it does not exist on-chain: check it for a typo (a missing or extra character), or send it a little SOL first"
    if acc.get("owner") != SYSTEM_PROGRAM:
        return "it is not a regular wallet (owner %s)" % acc.get("owner")
    return None


def payout_wallet():
    """(wallet, the setting it came from): BAMBOOST_PAYOUT_WALLET or, if that is empty, the first other
    *_PAYOUT_WALLET set in the config (another module's wallet). (None, None) when there is none."""
    if CONF.get("BAMBOOST_PAYOUT_WALLET"):
        return CONF["BAMBOOST_PAYOUT_WALLET"], "BAMBOOST_PAYOUT_WALLET"
    for k, v in CONF.items():
        if k.endswith("_PAYOUT_WALLET") and v:
            return v, k
    return None, None


def vote_identity(url, vote):
    """The identity a vote account belongs to on-chain, or None."""
    acc = account(url, vote)
    if not acc or acc.get("owner") != VOTE_PROGRAM:
        return None
    data = base64.b64decode(acc["data"][0])
    return b58e(data[4:36]) if len(data) >= 36 else None


def local_identity():
    """Who the local validator runs as right now, or None: getIdentity on its own RPC, else
    agave-validator contact-info (through the admin socket in the ledger)."""
    url = CONF.get("RPC_URL") or LOCAL_RPC
    if re.match(r"https?://(127\.0\.0\.1|localhost)[:/]", url + "/"):
        try:
            return rpc(url, "getIdentity", [], tries=1)["identity"]
        except Exception:
            pass
    agave, ledger = CONF.get("VALIDATOR_BIN"), CONF.get("LEDGER_DIR")
    if agave and ledger:
        try:
            out = subprocess.run([agave, "-l", ledger, "contact-info"], capture_output=True, text=True,
                                 timeout=30).stdout
            m = re.search(r"^Identity:\s*(\S+)", out, re.M)
            if m:
                return m.group(1)
        except Exception:
            pass
    return None


# --- log -----------------------------------------------------------------------
def ts():
    """Log time: BAMBOOST_LOG_TZ (like Asia/Tokyo), or the server's time."""
    tz = CONF.get("BAMBOOST_LOG_TZ")
    if tz:
        try:
            from zoneinfo import ZoneInfo
            return datetime.datetime.now(ZoneInfo(tz)).strftime("%Y-%m-%d %H:%M %Z")
        except Exception:
            pass
    return time.strftime("%Y-%m-%d %H:%M %Z")


def log_lines(lines, path=None):
    """lines: [(level, text)], level info or alarm. Written to the log as "time  text"; a text that is
    already among the last 30 lines is not written again. Over LOG_MAX the file moves to .1 (one old
    copy). Returns the lines really written: those go to Telegram. If the log can't be written, returns
    all of them (better to hear about a failure twice)."""
    path = path or LOG_PATH
    written = []
    if not lines:
        return written
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path) and os.path.getsize(path) > LOG_MAX:
            os.replace(path, path + ".1")
        recent = []
        if os.path.exists(path):
            with open(path, "rb") as f:
                f.seek(max(0, os.path.getsize(path) - 8192))
                recent = [l.split("  ", 1)[-1] for l in f.read().decode("utf-8", "replace").splitlines()[-30:]]
        stamp = ts()
        with open(path, "a", encoding="utf-8") as f:
            for level, body in lines:
                if body in recent:
                    continue
                f.write("%s  %s\n" % (stamp, body))
                recent.append(body)
                written.append((level, body))
    except Exception as ex:
        print("log %s: %s" % (path, ex), file=sys.stderr)
        written = [(lv, b + "  [log not written: %s]" % type(ex).__name__) for lv, b in lines]
    return written


# --- Telegram ------------------------------------------------------------------
def tg_conf():
    """(token, info chat, alarm chat) from the config, or Nones. Alarms go to TG_CHAT_ALARM, else to TG_CHAT_ID."""
    token, chat = CONF.get("TG_BOT_TOKEN"), CONF.get("TG_CHAT_ID")
    if not (token and chat):
        return None, None, None
    return token, chat, CONF.get("TG_CHAT_ALARM") or chat


def tg_send(chat, text, token):
    """True if Telegram took it. The token never shows up in the output, only the error type does."""
    if not (token and chat):
        return False
    try:
        data = urllib.parse.urlencode({"chat_id": chat, "text": text[:3900], "disable_web_page_preview": "true"}).encode()
        req = urllib.request.Request("https://api.telegram.org/bot%s/sendMessage" % token, data=data)
        with urllib.request.urlopen(req, timeout=15) as r:
            return bool(json.load(r).get("ok"))
    except Exception as ex:
        print("Telegram: not sent (%s)" % type(ex).__name__, file=sys.stderr)
        return False


def notify(written):
    """What went into the log goes to Telegram: info as one message to the info chat, alarms to the alarm chat."""
    if not written or CONF.get("BAMBOOST_TG", "1") != "1":
        return
    token, info_chat, alarm_chat = tg_conf()
    if not token:
        return
    for level, mark, chat in (("info", "\U0001F4B0", info_chat), ("alarm", "\U0001F6A8", alarm_chat)):
        lines = [b for lv, b in written if lv == level]
        if lines:
            tg_send(chat, "%s BAM Boost\n%s" % (mark, "\n".join(lines)), token)


# --- key -----------------------------------------------------------------------
def load_key(path):
    """(secret seed, public key) from a solana keypair file. ValueError if it is not one."""
    try:
        with open(path) as f:
            raw = bytes(json.load(f))
    except (OSError, ValueError, TypeError) as ex:
        raise ValueError("cannot read keypair %s (%s)" % (path, type(ex).__name__))
    if len(raw) != 64:
        raise ValueError("keypair %s: expected 64 bytes" % path)
    seed, pub = raw[:32], raw[32:]
    if ed_pub(seed) != pub:
        raise ValueError("keypair %s: its public key does not match the secret key" % path)
    return seed, pub


# --- main ----------------------------------------------------------------------
STATE = {"live": False}    # run_main() alarms only when a live run crashes


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="bamboost.py",
        description="Jito BAM Boost: claim to the identity, then pay the JitoSOL out to your payout wallet. "
                    "No warranty: you run it at your own risk (README.md, Disclaimer).")
    ap.add_argument("--live", action="store_true", help="send the transactions (needs BAMBOOST_DRY_RUN=0)")
    ap.add_argument("--auto", action="store_true", help="timer mode: live unless BAMBOOST_DRY_RUN=1 or --dry")
    ap.add_argument("--dry", "--dry-run", dest="dry", action="store_true", help="only simulate, with --auto too")
    ap.add_argument("--no-sweep", action="store_true", help="claim only, no payout")
    ap.add_argument("--sweep-only", action="store_true", help="payout only, no claims")
    ap.add_argument("--from", dest="efrom", type=int, metavar="EPOCH", help="first epoch (default: the oldest open one)")
    ap.add_argument("--to", dest="eto", type=int, metavar="EPOCH", help="last epoch (default: the current one)")
    ap.add_argument("--rpc", metavar="URL", help="RPC to use (default: BAMBOOST_RPC_URL)")
    ap.add_argument("--key", metavar="PATH", help="identity keypair (default: IDENTITY_KEYPAIR)")
    ap.add_argument("--close", action="store_true",
                    help="manual only: after the payout, close the JitoSOL account of the identity (its rent comes back)")
    ap.add_argument("--version", action="store_true", help="print the version and exit")
    ap.add_argument("--tg-test", action="store_true", help="send a test message to the info chat and the alarm chat")
    a = ap.parse_args(argv)
    if a.version:
        print("bamboost %s" % VERSION)
        return
    load_conf()
    host = socket.gethostname().split(".")[0]
    if a.tg_test:
        if not conf_01("BAMBOOST_TG", "1"):
            sys.exit("Telegram is off for bamboost: BAMBOOST_TG=0 in %s" % ENV_PATH)
        token, info_chat, alarm_chat = tg_conf()
        if not token:
            sys.exit("no Telegram in %s (TG_BOT_TOKEN, TG_CHAT_ID): run install.sh to set it up" % ENV_PATH)
        ok1 = tg_send(info_chat, "\U0001F514 BAM Boost on %s: test, info chat (bamboost %s)" % (host, VERSION), token)
        ok2 = ok1 if alarm_chat == info_chat else tg_send(
            alarm_chat, "\U0001F514 BAM Boost on %s: test, alarm chat (bamboost %s)" % (host, VERSION), token)
        print("Telegram: info %s, alarm %s%s" % ("sent" if ok1 else "NOT sent", "sent" if ok2 else "NOT sent",
                                                 " (the same chat)" if alarm_chat == info_chat else ""))
        return
    if a.close and (a.auto or a.no_sweep):
        sys.exit("--close is manual only, together with the payout (not with --auto or --no-sweep)")
    dry_conf = conf_01("BAMBOOST_DRY_RUN", "1")
    conf_01("BAMBOOST_TG", "1")                 # only checks the value
    if a.live and dry_conf and not a.dry:
        sys.exit("BAMBOOST_DRY_RUN=1 in %s: dry runs only. Set it to 0 once a dry run looks right" % ENV_PATH)
    live = (a.live or a.auto) and not (a.dry or dry_conf)
    STATE["live"] = live
    quiet = a.auto and live                     # the timer prints only when it did something
    hdr, events, logl = [], [], []              # logl: lines for the log, written only in a live run
    say = (lambda s: events.append(s)) if quiet else print
    head = (lambda s: hdr.append(s)) if quiet else print
    info = (lambda s: None) if quiet else print   # details the timer doesn't need

    def finish(code=0):
        if live:
            notify(log_lines(logl))
        if quiet and events:
            print("\n".join(hdr + events))
        if code:
            sys.exit(code)

    def stop(why):                              # a setup problem: a live run also logs it and alarms once
        if live:
            notify(log_lines([("alarm", "%s  %s  STOP: %s" % (VERSION, host, why))]))
        sys.exit(why)

    url = a.rpc or CONF.get("BAMBOOST_RPC_URL") or RPC_DEFAULT
    hours = conf_int("BAMBOOST_CURRENT_AFTER_HOURS", 12, 0, 72)
    backup_after = conf_int("BAMBOOST_BACKUP_AFTER", 10, 1, WINDOW - 1)
    path = a.key or CONF.get("IDENTITY_KEYPAIR")
    if not path:
        stop("IDENTITY_KEYPAIR is not set in %s: run install.sh, or give --key" % ENV_PATH)
    try:
        seed, ident = load_key(path)
    except ValueError as ex:
        stop(str(ex))
    idb = b58e(ident)
    vote = CONF.get("VOTE_ACCOUNT", "")
    if not is_addr(vote):
        stop("VOTE_ACCOUNT is not set in %s: run install.sh" % ENV_PATH)
    node = vote_identity(url, vote)
    if node != idb:
        stop("keypair %s is identity %s, but vote account %s belongs to %s"
             % (path, idb, vote, node or "an identity it can't read"))
    wallet_b58, wallet_from = payout_wallet()
    if not wallet_b58:
        stop("no payout wallet: enter BAMBOOST_PAYOUT_WALLET in %s (or run install.sh). "
             "bamboost never runs without an explicit payout wallet" % ENV_PATH)
    problem = payout_problem(url, wallet_b58, idb, vote)
    if problem:
        stop("%s %s: %s" % (wallet_from, wallet_b58, problem))
    wallet = b58d(wallet_b58)
    src_b58, dst_b58 = b58e(ata(ident)), b58e(ata(wallet))

    head("bamboost %s | %s | %s" % (VERSION, host, "AUTO" if quiet else (
        "AUTO, dry run: simulation only" if a.auto else ("LIVE" if live else "DRY RUN: simulation only"))))
    if wallet_from != "BAMBOOST_PAYOUT_WALLET":
        head("WARNING: BAMBOOST_PAYOUT_WALLET is empty, so the payout goes to %s (%s)" % (wallet_from, wallet_b58))

    # --- the voting node of a pair, or a spare (--auto only; a manual run works from any node)
    active = True
    if a.auto:
        lid = local_identity()
        active = lid == idb
        if not quiet:
            print("local validator: %s, %s" % (
                lid or "not answering",
                "the voting identity: normal mode" if active
                else "not the voting identity: spare insurance (only epochs unclaimed for %d+ epochs)" % backup_after))
    tag = "%s  %s  %s" % (VERSION, host, ("auto" if active else "spare") if a.auto else "manual")

    ep = rpc(url, "getEpochInfo", [{"commitment": "confirmed"}])
    cur = ep["epoch"]
    lam0 = rpc(url, "getBalance", [idb, {"commitment": "confirmed"}])["value"]
    head("identity %s  (%s)" % (idb, path))
    head("Telegram: %s" % ("on" if tg_conf()[0] and CONF.get("BAMBOOST_TG", "1") == "1" else "off, the log only"))
    head("claim -> %s (JitoSOL account of the identity), payout -> %s (JitoSOL account of wallet %s)"
         % (src_b58, dst_b58, wallet_b58))
    head("identity balance %.4f SOL | epoch %d, ~%.1f h left"
         % (lam0 / 1e9, cur, (ep["slotsInEpoch"] - ep["slotIndex"]) * 0.212 / 3600))
    if live and lam0 < 0.05e9:
        say("less than 0.05 SOL on the identity: stop")
        logl.append(("alarm", "%s  STOP: %.4f SOL on the identity (< 0.05)" % (tag, lam0 / 1e9)))
        finish(1)

    claimed_ok, total = [], 0
    if not a.sweep_only:
        lo = a.efrom if a.efrom is not None else cur - WINDOW + 1
        hi = a.eto if a.eto is not None else cur
        epochs = list(range(lo, hi + 1))
        dists = [distributor(e) for e in epochs]
        keys = [b58e(claim_status(ident, d)) for d in dists] + [b58e(d) for d in dists]
        accs = []
        for n in range(0, len(keys), 100):
            accs += rpc(url, "getMultipleAccounts", [keys[n:n + 100], {"encoding": "base64", "commitment": "confirmed"}])["value"]
        k = len(epochs)
        claimed = {e for e, acc in zip(epochs, accs[:k]) if acc}
        roots = {e: (base64.b64decode(acc["data"][0])[9:41] if acc else None) for e, acc in zip(epochs, accs[k:])}
        age = None
        if not live:
            if token_amount(url, src_b58) is not None:
                print("(each claimed epoch costs the identity ~0.0009 SOL: the ClaimStatus rent, not refundable)")
            else:
                print("(the identity has no JitoSOL account yet: in a dry run every simulation creates it again, "
                      "~-0.0024 SOL each; live, the first claim costs ~0.0024 (0.0015 of it is the account rent, "
                      "it stays on the account), the next ones ~0.0009)")
        for e in epochs:
            if e in claimed:
                info("%d  already claimed" % e)
                continue
            left = e + WINDOW - 1 - cur          # epochs after the current one in which it can still be claimed
            if left < 0 and live:                # older than E+19: the program would answer ClaimExpired, don't send
                info("%d  window closed (past E+19), skip" % e)
                continue
            if a.auto and e == cur:
                age = epoch_age_h(url, ep) if age is None else age
                if age < hours:
                    info("%d  current epoch: %.1f h old, claimed after %d h" % (e, age, hours))
                    continue
            if a.auto and not active and cur - e < backup_after:
                info("%d  unclaimed for %d epochs (< %d): the voting node's job" % (e, cur - e, backup_after))
                continue
            if roots[e] is None:
                info("%d  no distributor for this epoch on-chain" % e)
                continue
            ok, amount = False, None
            try:
                amount, proof, root = tree_proof(e, ident)
            except Exception as ex:
                say("%d  could not get the tree from GCS: %s; the next run tries again" % (e, str(ex)[:80]))
                logl.append(("alarm", "%s  e%d  could not get the tree from GCS" % (tag, e)))
            if amount is not None and amount <= 0:
                info("%d  not in the tree" % e)
                continue
            if amount is not None and root != roots[e]:
                say("%d  the GCS tree root does not match the on-chain root, skip" % e)
                logl.append(("alarm", "%s  e%d  the GCS tree root does not match the on-chain root, skip" % (tag, e)))
                amount = None
            if amount is not None and not live:
                tx, sig = build_claim(seed, ident, e, amount, proof, latest_bh(url))
                v = simulate(url, tx, [idb, src_b58])
                if v["err"] is None:
                    total += amount
                    ok = True
                    post = v.get("accounts") or [None, None]
                    d_sol = ((post[0] or {}).get("lamports", lam0) - lam0) / 1e9
                    print("%d  %.4f  OK (simulated: identity %+.5f SOL, its JitoSOL account will hold %.4f)"
                          % (e, amount / 1e9, d_sol, post_token(post[1])))
                else:
                    print("%d  %.4f  %s" % (e, amount / 1e9, describe(v["err"], v.get("logs"))))
                time.sleep(0.3)
            elif amount is not None:
                cs = b58e(claim_status(ident, distributor(e)))

                def claimed_now(cs=cs):
                    return account(url, cs) is not None

                st, sig = send(url, lambda bh, e=e, amount=amount, proof=proof: build_claim(seed, ident, e, amount, proof, bh),
                               claimed_now)
                if done_ok(st):
                    total += amount
                    ok = True
                    claimed_ok.append((e, amount))
                else:
                    logl.append(("alarm", "%s  e%d  claim FAILED: %s" % (tag, e, st[:140])))
                say("%d  %.4f  claim %s  %s" % (e, amount / 1e9, st, sig))
                time.sleep(1)
            if not ok and 0 <= left <= WARN_LEFT:
                w = "WARNING: e%d is not claimed, %s" % (e, "it expires at the end of this epoch" if left <= 0
                                                       else "it expires in %d epochs" % left)
                say(w)
                logl.append(("alarm", "%s  %s" % (tag, w)))
        if not quiet or total:
            say("claimed in total: %.4f JitoSOL" % (total / 1e9))

    swept = 0
    if not a.no_sweep and (active or total > 0):    # a spare pays out only what it claimed itself
        bal = token_amount(url, src_b58)
        hint = " (live, it is paid out after the claim)" if not live and total else ""
        if bal is None:
            info("payout: the identity has no JitoSOL account, nothing to pay out" + hint)
        elif bal == 0 and not a.close:
            info("payout: the JitoSOL account of the identity is empty, nothing to pay out" + hint)
        else:
            cl = " + close the JitoSOL account of the identity (the identity itself is not touched)" if a.close else ""
            if not live:
                tx, sig = build_sweep(seed, ident, wallet, bal, latest_bh(url), a.close)
                v = simulate(url, tx, [idb, dst_b58])
                if v["err"] is None:
                    post = v.get("accounts") or [None, None]
                    d_sol = ((post[0] or {}).get("lamports", lam0) - lam0) / 1e9
                    print("payout %.4f JitoSOL -> %s%s: OK (simulated: identity %+.5f SOL, the wallet will hold %.4f JitoSOL)"
                          % (bal / 1e9, wallet_b58, cl, d_sol, post_token(post[1])))
                else:
                    print("payout: %s" % describe(v["err"], v.get("logs")))
            else:
                box = {"bal": bal, "sent": bal}

                def build(bh):
                    box["sent"] = box["bal"]
                    return build_sweep(seed, ident, wallet, box["bal"], bh, a.close)

                def swept_already():
                    now = token_amount(url, src_b58)
                    if a.close:
                        return now is None
                    if now:                     # something is left: the next try pays out all of it
                        box["bal"] = now
                        return False
                    return True

                st, sig = send(url, build, swept_already)
                if done_ok(st):
                    swept = box["sent"]
                else:
                    logl.append(("alarm", "%s  payout %.4f FAILED: %s" % (tag, box["sent"] / 1e9, st[:140])))
                say("payout %.4f JitoSOL -> %s%s: %s  %s" % (box["sent"] / 1e9, wallet_b58, cl, st, sig))

    if live and (claimed_ok or swept):
        parts = []
        if claimed_ok:
            parts.append("claim %s %.4f ok" % ("+".join("e%d" % e for e, _ in claimed_ok),
                                               sum(x for _, x in claimed_ok) / 1e9))
        if swept:
            parts.append("payout %.4f -> %s ok" % (swept / 1e9, wallet_b58[:5]))
        try:
            parts.append("identity %.4f SOL" % (rpc(url, "getBalance", [idb, {"commitment": "confirmed"}])["value"] / 1e9))
        except Exception:
            pass
        logl.append(("info", "%s  %s" % (tag, "  ".join(parts))))
    finish()
    if not quiet:
        try:
            w = token_amount(url, dst_b58)
        except Exception:
            w = None
        print("wallet %s: %s" % (wallet_b58, "%.4f JitoSOL" % (w / 1e9) if w is not None
                                  else "0 JitoSOL (its JitoSOL account is created by the first payout)"))
        if live:
            print("log: %s" % LOG_PATH)


def run_main():
    """main() with a guard: an unexpected crash of a live run goes to the log and to the alarm chat."""
    try:
        main()
    except Exception as ex:
        if STATE["live"]:
            body = "%s  %s  crashed: %s: %s" % (VERSION, socket.gethostname().split(".")[0], type(ex).__name__,
                                                 str(ex)[:120])
            notify(log_lines([("alarm", body)]))
        raise


if __name__ == "__main__":
    run_main()
