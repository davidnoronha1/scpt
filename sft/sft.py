#!/usr/bin/env python3
"""sft — drag-and-drop file copy into a remote home folder.

Run it, it picks (or asks for) a remote target, then sits in a loop:
drag a file/folder from your file manager into the terminal window,
press enter, it copies to ~/ on the remote with a progress bar, and
waits for the next drop. Type q or Ctrl-C to quit.

Target resolution:
  1. An already-active SSH ControlMaster connection (shared with the
     scpt tool's connections, ~/.ssh/cm-*) is reused automatically —
     no re-auth, no prompt, if exactly one is active.
  2. Otherwise hosts already saved in ~/.ssh/config (or the fallback
     XDG_CONFIG_HOME/scpt/hosts when ~/.ssh is not writable) under the
     same "# tmux-remote-helper" marker scpt.sh uses are offered as picks.
  3. Otherwise you're prompted for a host (user@host or an alias),
      with the option to save it for next time.

Transfer: rsync --info=progress2 (required). Uses ControlMaster for
auth reuse. docker cp is the only exception for docker targets.

Bootstrap (-b):
  sft -b [host]  copy sft itself to the remote's ~/.local/bin so the
                 remote can run sft natively. Uses the same ControlMaster
                 connection (no re-auth). Remote ~/.local/bin is created
                 if needed and file is chmod +x.

Host storage fallback:
  ~/.ssh and ~/.ssh/config are never chmod/chown'd to "fix" perms.
  If ~/.ssh/config is not writable (or not readable), hosts are stored
  in XDG_CONFIG_HOME/scpt/hosts (default: ~/.config/scpt/hosts) which is
  shared with scpt. Saved hosts from both locations are merged for picks,
  and the ssh target automatically uses user@host when the alias lives
  only in the fallback (so no ~/.ssh/config alias resolution needed).
"""
import glob
import json
import os
import re
import select
import shlex
import shutil
import subprocess
import sys
import termios
import time
import tty
from pathlib import Path

HOME = Path.home()
SSH_CONFIG = HOME / ".ssh" / "config"
MARKER = "# tmux-remote-helper"
# Fallback outside ~/.ssh — used when ~/.ssh/config is not readable/writable
# (we never chmod/chown ~/.ssh to "fix" permissions; we just store elsewhere).
# Both sft and scpt share this file so hosts added in one appear in the other.
_FALLBACK_BASE = Path(os.environ.get("XDG_CONFIG_HOME", str(HOME / ".config")))
FALLBACK_SSH_CONFIG = _FALLBACK_BASE / "scpt" / "hosts"

IS_TTY = sys.stdout.isatty()


def _c(code):
    return f"\033[{code}m" if IS_TTY else ""


C_RESET = _c(0)
C_BOLD = _c(1)
C_DIM = _c(2)
C_RED = _c(31)
C_GREEN = _c(32)
C_YELLOW = _c(33)
C_CYAN = _c(36)
C_MAGENTA = _c(35)


def log_info(msg):
    print(f"{C_CYAN}→{C_RESET} {msg}")


def log_ok(msg):
    print(f"{C_GREEN}✓{C_RESET} {msg}")


def log_warn(msg):
    print(f"{C_YELLOW}⚠{C_RESET} {msg}", file=sys.stderr)


def log_error(msg):
    print(f"{C_RED}✗{C_RESET} {msg}", file=sys.stderr)


def log_dim(msg):
    print(f"{C_DIM}{msg}{C_RESET}")


def require(cmd):
    if not shutil.which(cmd):
        log_error(f"{cmd} is required but not installed.")
        sys.exit(1)


# ── saved hosts (shared format/marker with scpt.sh) ─────────────────────
def _parse_hosts_from_text(text):
    """Parse Host blocks marked with MARKER from a config string."""
    lines = text.splitlines()
    managed = False
    alias = hn = usr = idf = x11 = None
    was_managed = False
    yield_list = []
    for line in lines:
        if line.strip() == MARKER:
            managed = True
            continue
        m = re.match(r"^[Hh]ost\s+(\S+)", line)
        if m:
            if alias and was_managed:
                yield_list.append((alias, hn or "", usr or "", idf or "", x11 or ""))
            alias, hn, usr, idf, x11 = m.group(1), "", "", "", ""
            was_managed, managed = managed, False
            continue
        if was_managed:
            m = re.match(r"^\s*[Hh]ost[Nn]ame\s+(\S+)", line)
            if m:
                hn = m.group(1)
            m = re.match(r"^\s*[Uu]ser\s+(\S+)", line)
            if m:
                usr = m.group(1)
            m = re.match(r"^\s*[Ii]dentity[Ff]ile\s+(\S+)", line)
            if m:
                idf = m.group(1)
            m = re.match(r"^\s*ForwardX11\s+(\S+)", line)
            if m and m.group(1).lower() == "yes":
                x11 = "yes"
    if alias and was_managed:
        yield_list.append((alias, hn or "", usr or "", idf or "", x11 or ""))
    return yield_list


def _hosts_from_file(path: Path):
    """Read hosts from a single file; returns [] if missing/unreadable."""
    try:
        if not path.exists():
            return []
    except (PermissionError, OSError):
        # Expected when ~/.ssh is intentionally not readable (fallback mode) — silent
        return []
    try:
        text = path.read_text(errors="ignore")
    except (PermissionError, OSError):
        return []
    return _parse_hosts_from_text(text)


def list_saved_hosts():
    """Returns (alias, hostname, user, identityfile, x11) for hosts saved under MARKER.

    Reads both ~/.ssh/config (if readable) and the fallback file
    FALLBACK_SSH_CONFIG (XDG_CONFIG_HOME/scpt/hosts). We never attempt to
    chmod/chown ~/.ssh to make it readable — we simply skip it and use the
    fallback. Results are deduplicated by alias (primary config wins).
    x11 is 'yes' if ForwardX11 enabled, else ''.
    """
    seen = set()
    out = []
    for cfg in (SSH_CONFIG, FALLBACK_SSH_CONFIG):
        for alias, hn, usr, idf, x11 in _hosts_from_file(cfg):
            if alias not in seen:
                seen.add(alias)
                out.append((alias, hn, usr, idf, x11))
    return out


def lookup_host(alias):
    """Return (hn, usr, idf, x11) for alias from saved hosts or None."""
    for a, hn, usr, idf, x11 in list_saved_hosts():
        if a == alias:
            return hn, usr, idf, x11
    return None


def alias_exists(alias):
    """True if alias exists in either primary or fallback store."""
    pattern = re.compile(rf"^Host\s+{re.escape(alias)}$", re.MULTILINE)
    for cfg in (SSH_CONFIG, FALLBACK_SSH_CONFIG):
        try:
            if not cfg.exists():
                continue
        except (PermissionError, OSError):
            continue
        try:
            text = cfg.read_text(errors="ignore")
        except (PermissionError, OSError):
            continue
        if pattern.search(text):
            return True
    return False


def alias_in_ssh_config(alias):
    """True only if alias exists in the primary ~/.ssh/config (readable)."""
    try:
        if not SSH_CONFIG.exists():
            return False
    except (PermissionError, OSError):
        return False
    try:
        text = SSH_CONFIG.read_text(errors="ignore")
    except (PermissionError, OSError):
        return False
    pattern = re.compile(rf"^Host\s+{re.escape(alias)}$", re.MULTILINE)
    return bool(pattern.search(text))


def _ssh_config_writable():
    """True if we can append to ~/.ssh/config without changing its perms.

    We deliberately do NOT chmod/chown ~/.ssh or ~/.ssh/config. If they
    are not writable by the current user we return False and let the
    caller use the fallback store instead.
    """
    ssh_dir = HOME / ".ssh"
    try:
        try:
            if SSH_CONFIG.exists():
                return os.access(str(SSH_CONFIG), os.W_OK)
        except (PermissionError, OSError):
            return False
        try:
            if ssh_dir.exists():
                return os.access(str(ssh_dir), os.W_OK)
        except (PermissionError, OSError):
            return False
        # no dir and no file — we could create them; check home writable
        return os.access(str(HOME), os.W_OK)
    except (PermissionError, OSError):
        return False
    return False


def save_host(alias, hn, usr, identityfile="", x11=""):
    """Save alias -> user@hostname. Tries ~/.ssh/config if writable,
    otherwise stores in FALLBACK_SSH_CONFIG without touching ~/.ssh perms.

    identityfile: optional path to keyfile (e.g. AWS .pem) for publickey auth.
    When empty, SSH agent / default keys are used. Password auth stores no
    IdentityFile (ssh prompts).
    x11: 'yes' to enable ForwardX11 (like scpt), else ''.
    """
    if alias_exists(alias):
        # find where it lives for a better warning
        where = str(SSH_CONFIG) if alias_in_ssh_config(alias) else str(FALLBACK_SSH_CONFIG)
        log_warn(f"Alias '{alias}' already exists in {where} — not overwriting.")
        return False

    def _write_block(f, alias, hn, usr, idf, x11flag):
        f.write("\n")
        f.write(MARKER + "\n")
        f.write(f"Host {alias}\n")
        f.write(f"    HostName {hn}\n")
        f.write(f"    User {usr}\n")
        if idf:
            f.write(f"    IdentityFile {idf}\n")
        if x11flag == "yes":
            f.write(f"    ForwardX11 yes\n")
            f.write(f"    ForwardX11Trusted yes\n")
        f.write("    ControlMaster auto\n")
        f.write("    ControlPath ~/.ssh/cm-%r@%h:%p\n")
        f.write("    ControlPersist 10m\n")

    # Prefer primary if writable; else fallback.
    if _ssh_config_writable():
        target = SSH_CONFIG
        try:
            # Create ~/.ssh if missing (only when writable); otherwise this
            # mkdir would fail and we fall through to fallback.
            target.parent.mkdir(mode=0o700, exist_ok=True)
        except (PermissionError, OSError):
            pass
        try:
            with open(target, "a") as f:
                _write_block(f, alias, hn, usr, identityfile, x11)
            # Only chmod the file we just wrote, and only if we own it —
            # never chmod ~/.ssh itself if we didn't create it.
            try:
                os.chmod(target, 0o600)
            except (PermissionError, OSError):
                pass
            # Verify it actually got written
            if alias_in_ssh_config(alias):
                return True
        except (PermissionError, OSError) as e:
            log_warn(f"Could not write {target}: {e} — trying fallback")
        # fall through to fallback

    # Fallback: XDG config location, never touches ~/.ssh perms
    target = FALLBACK_SSH_CONFIG
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(target.parent, 0o700)
        except (PermissionError, OSError):
            pass
        with open(target, "a") as f:
            _write_block(f, alias, hn, usr, identityfile, x11)
        try:
            os.chmod(target, 0o600)
        except (PermissionError, OSError):
            pass
        log_info(f"Saved host '{alias}' to fallback {target} ( ~/.ssh/config not writable )")
        return True
    except (PermissionError, OSError) as e:
        log_warn(f"Could not write fallback {target}: {e}")
        return False


# ── active ControlMaster sockets (shared with scpt.sh) ───────────────────
def list_active_ssh():
    """Yields (userhost, hn, usr, sock) for live ControlMaster sockets."""
    out = []
    for sock in glob.glob(str(HOME / ".ssh" / "cm-*")):
        base = os.path.basename(sock)[len("cm-"):]
        if ":" not in base or "@" not in base:
            continue
        userhost = base.rsplit(":", 1)[0]
        usr, _, hn = userhost.partition("@")
        if not usr or not hn:
            continue
        rc = subprocess.run(
            ["ssh", "-O", "check", "-S", sock, "x"],
            capture_output=True,
        ).returncode
        if rc != 0:
            continue
        out.append((userhost, hn, usr, sock))
    return out


# ── choosing a target ───────────────────────────────────────────────────
class Target:
    label = ""
    ssh = ""
    control_path = ""
    owns_master = False
    identityfile = ""  # optional IdentityFile for -i (keyfile auth)
    x11 = ""           # 'yes' if ForwardX11 enabled (scpt compatible)

    # Effective ssh args derived from identityfile; used by warm_control_master
    # and transfer functions. Fallback hosts not in ~/.ssh/config need explicit -i.


# ── listing remotes (-l) ──────────────────────────────────────────────────
def print_remotes():
    """Print saved aliases and active ControlMaster connections (for -l)."""
    active = list_active_ssh()
    saved = list_saved_hosts()

    print(f"{C_BOLD}Active connections (ControlMaster):{C_RESET}")
    if active:
        for userhost, hn, usr, sock in active:
            # show live check already done in list_active_ssh
            print(f"  {C_GREEN}●{C_RESET} {userhost} {C_DIM}→ {usr}@{hn}  ({sock}){C_RESET}")
    else:
        print(f"  {C_DIM}(none){C_RESET}")

    print(f"\n{C_BOLD}Saved remotes ({len(saved)}):{C_RESET}")
    if saved:
        for alias, hn, usr, idf, x11 in saved:
            where = "fallback" if not alias_in_ssh_config(alias) else "~/.ssh/config"
            idf_str = f" {C_DIM}[{os.path.basename(idf)}]{C_RESET}" if idf else ""
            x11_str = f" {C_DIM}[X11]{C_RESET}" if x11 == "yes" else ""
            # infer auth method tag
            if idf:
                tag = "keyfile"
            elif usr and hn:
                tag = "key/agent or password"
            else:
                tag = ""
            tag_str = f" {C_DIM}({tag}){C_RESET}" if tag else ""
            print(f"  {C_CYAN}{alias}{C_RESET} {C_DIM}→{C_RESET} {usr}@{hn}{idf_str}{x11_str}{tag_str} {C_DIM}[{where}]{C_RESET}")
    else:
        print(f"  {C_DIM}(none){C_RESET}")
        print(f"  {C_DIM}Add one: sft will prompt, or add via scpt / manually edit ~/.ssh/config{C_RESET}")

    # also hint file usage
    print(f"\n{C_DIM}Usage: sft <alias> <FILE>  — copy file(s) to remote ~/  (supports key, keyfile, password){C_RESET}")


def pick_from_list(labels):
    for i, label in enumerate(labels, 1):
        print(f"  {C_BOLD}{i}){C_RESET} {label}")
    try:
        choice = input(f"{C_CYAN}Pick [1-{len(labels)}]: {C_RESET}")
    except EOFError:
        return None
    if choice.isdigit() and 1 <= int(choice) <= len(labels):
        return int(choice) - 1
    return None


def _ssh_extra_opts(target: Target):
    """Extra ssh opts for target (IdentityFile for keyfile auth / fallback hosts, X11)."""
    opts = []
    if getattr(target, "identityfile", ""):
        # Expand ~ and ensure file exists warning if not
        idf = os.path.expanduser(target.identityfile)
        opts += ["-i", idf]
    if getattr(target, "x11", "") == "yes":
        opts += ["-X"]
    return opts


def warm_control_master(target: Target):
    target.control_path = str(HOME / ".ssh" / f"cm-sft-{os.getpid()}")
    target.owns_master = True
    log_info(f"Connecting to {C_BOLD}{target.label}{C_RESET}...")
    cmd = [
        "ssh", "-MNf",
        "-o", f"ControlPath={target.control_path}",
        "-o", "ControlPersist=10m",
        "-o", "ConnectTimeout=10",
    ] + _ssh_extra_opts(target) + [target.ssh]
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        log_error(f"Could not connect to {target.label}:")
        log_dim(proc.stderr.strip())
        sys.exit(1)
    log_ok("Connected.")


def resolve_target() -> Target:
    target = Target()
    active = list_active_ssh()

    if len(active) == 1:
        userhost, hn, usr, sock = active[0]
        target.label = target.ssh = userhost
        target.control_path = sock
        target.owns_master = False
        log_ok(f"Reusing active connection to {C_BOLD}{userhost}{C_RESET} {C_DIM}(ControlMaster){C_RESET}")
        return target

    if len(active) > 1:
        print(f"{C_BOLD}Multiple active connections — pick one:{C_RESET}")
        labels = [f"{uh} {C_DIM}(active){C_RESET}" for uh, *_ in active]
        idx = pick_from_list(labels)
        if idx is None:
            log_error("Invalid choice.")
            sys.exit(1)
        userhost, hn, usr, sock = active[idx]
        target.label = target.ssh = userhost
        target.control_path = sock
        target.owns_master = False
        return target

    saved = list_saved_hosts() or []
    if saved:
        print(f"{C_BOLD}Saved hosts:{C_RESET}")
        labels = [f"{alias} {C_DIM}→ {usr}@{hn}{C_RESET}" for alias, hn, usr, _idf, _x11 in saved]
        labels.append(f"{C_DIM}(type a new host instead){C_RESET}")
        idx = pick_from_list(labels)
        if idx is not None and idx < len(saved):
            alias, hn, usr, idf, x11 = saved[idx]
            target.label = alias
            target.identityfile = idf or ""
            target.x11 = x11 or ""
            # If alias lives only in fallback (not in ~/.ssh/config), ssh won't
            # resolve it — use explicit user@host instead. Primary aliases keep
            # using the alias so ssh config options (ControlMaster etc.) apply.
            if alias_in_ssh_config(alias):
                target.ssh = alias
            else:
                target.ssh = f"{usr}@{hn}" if usr and hn else alias
                log_dim(f"(host '{alias}' from fallback {FALLBACK_SSH_CONFIG} — using {target.ssh})")
            warm_control_master(target)
            return target

    try:
        manual = input(f"{C_CYAN}Copy to which host? (user@host or alias): {C_RESET}").strip()
    except EOFError:
        manual = ""
    if not manual:
        log_error("No host given.")
        sys.exit(1)
    target.label = target.ssh = manual

    # Alias entered directly that lives only in fallback — need explicit user@host
    if "@" not in manual and alias_exists(manual) and not alias_in_ssh_config(manual):
        hit = lookup_host(manual)
        if hit:
            _h, _u, _idf, _x11 = hit
            target.ssh = f"{_u}@{_h}" if _u and _h else manual
            target.identityfile = _idf or ""
            target.x11 = _x11 or ""
            log_dim(f"(host '{manual}' from fallback {FALLBACK_SSH_CONFIG} — using {target.ssh})")
            if _idf:
                log_dim(f"(using keyfile {_idf})")
            if _x11 == "yes":
                log_dim(f"(X11 forwarding enabled)")

    if "@" in manual and not alias_exists(manual):
        try:
            save_ans = input(f"{C_CYAN}Save '{manual}' to ~/.ssh/config for next time? [y/N]: {C_RESET}")
        except EOFError:
            save_ans = ""
        if save_ans.strip().lower().startswith("y"):
            new_alias = input("Alias for this host: ").strip()
            if new_alias:
                usr, _, hn = manual.partition("@")
                # ── ask auth method (mirrors scpt's 3 methods) ──────────
                print(f"{C_BOLD}Auth method for this host:{C_RESET}")
                print(f"  {C_DIM}1){C_RESET} SSH key (agent/default)")
                print(f"  {C_DIM}2){C_RESET} Keyfile (e.g. AWS .pem)")
                print(f"  {C_DIM}3){C_RESET} Password")
                try:
                    auth_choice = input(f"{C_CYAN}Pick auth [1-3] (default 1): {C_RESET}").strip()
                except EOFError:
                    auth_choice = ""
                if not auth_choice:
                    auth_choice = "1"
                idf = ""
                if auth_choice == "2":
                    try:
                        idf = input(f"{C_CYAN}Path to keyfile: {C_RESET}").strip()
                    except EOFError:
                        idf = ""
                    idf = os.path.expanduser(idf) if idf else ""
                    if idf and not os.path.isfile(os.path.expanduser(idf)):
                        log_warn(f"file not found at {idf}")
                    else:
                        # store as given but expanded ~ -> keep $HOME style? store expanded
                        idf = idf.replace(os.path.expanduser("~"), "~") if idf.startswith(os.path.expanduser("~")) else idf
                        # revert: keep expanded for writing; scpt stores expanded path with ~
                        if idf.startswith("~"):
                            idf = os.path.expanduser(idf)
                elif auth_choice == "3":
                    log_dim("Password auth — ssh will prompt when connecting (nothing stored).")

                # ── ask X11 forwarding (like scpt) ──────────────────────
                try:
                    x11_ans = input(f"{C_CYAN}Enable X11 forwarding for this host (run GUI apps over ssh)? [y/N]: {C_RESET}").strip()
                except EOFError:
                    x11_ans = ""
                x11 = "yes" if x11_ans.lower().startswith("y") else ""

                if save_host(new_alias, hn, usr, idf, x11):
                    log_ok(f"Saved as '{new_alias}'.")
                    target.label = new_alias
                    target.identityfile = idf
                    target.x11 = x11
                    if alias_in_ssh_config(new_alias):
                        target.ssh = new_alias
                    else:
                        target.ssh = f"{usr}@{hn}" if usr and hn else new_alias
                        log_dim(f"(saved to fallback {FALLBACK_SSH_CONFIG} — using {target.ssh} for this connection)")

    warm_control_master(target)
    return target


def resolve_target_for_alias(alias: str) -> Target:
    """Resolve a specific alias/user@host to a Target without interactive picks.

    Used for `sft <alias> <FILE>` direct mode. Supports:
      - saved alias (primary or fallback) with optional IdentityFile (keyfile)
      - active ControlMaster (reuse, no re-auth)
      - raw user@host string (password / key / keyfile via ssh defaults)
    """
    target = Target()
    # Check active connections first — reuse if alias matches a live socket
    active = list_active_ssh()
    for userhost, hn, usr, sock in active:
        if alias == userhost or alias == hn or alias == f"{usr}@{hn}":
            target.label = target.ssh = userhost
            target.control_path = sock
            target.owns_master = False
            log_ok(f"Reusing active connection to {C_BOLD}{userhost}{C_RESET} {C_DIM}(ControlMaster){C_RESET}")
            return target

    # Check saved hosts
    hit = lookup_host(alias)
    if hit is not None:
        hn, usr, idf, x11 = hit
        target.label = alias
        target.identityfile = idf or ""
        target.x11 = x11 or ""
        if alias_in_ssh_config(alias):
            target.ssh = alias
        else:
            target.ssh = f"{usr}@{hn}" if usr and hn else alias
            log_dim(f"(host '{alias}' from fallback {FALLBACK_SSH_CONFIG} — using {target.ssh})")
        # If IdentityFile present, note auth method
        if idf:
            log_dim(f"(using keyfile {idf})")
        if x11 == "yes":
            log_dim(f"(X11 forwarding enabled)")
        warm_control_master(target)
        return target

    # Raw host (user@host) or unknown alias — treat as ssh target directly
    target.label = target.ssh = alias
    # If alias without @ and not found, it's an error (suggest -l)
    if "@" not in alias and not alias_exists(alias):
        log_warn(f"Alias '{alias}' not found — trying as raw host '{alias}'")
    warm_control_master(target)
    return target


def bootstrap_self(target: Target) -> bool:
    """Copy this sft script to remote ~/.local/bin/sft via the ControlMaster."""
    src = Path(__file__).resolve()
    if not src.is_file():
        log_error(f"Cannot locate sft source: {src}")
        return False
    log_info(f"Bootstrapping sft to {C_BOLD}{target.label}{C_RESET} → ~/.local/bin/sft ...")

    # Ensure remote ~/.local/bin exists
    ssh_mkdir = ["ssh", "-o", f"ControlPath={target.control_path}"] + _ssh_extra_opts(target) + [target.ssh, "mkdir -p ~/.local/bin && echo ok"]
    proc = subprocess.run(
        ssh_mkdir,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or "ok" not in proc.stdout:
        log_error(f"Failed to create ~/.local/bin on {target.label}: {proc.stderr.strip()}")
        return False

    # Transfer: rsync only (no scp fallback). Requires rsync.
    dest = f"{target.ssh}:~/.local/bin/sft"
    name = "sft"
    total_size = path_size(str(src))
    if not shutil.which("rsync"):
        log_error("rsync is required for sft (bootstrap and transfers). Install rsync.")
        return False
    # rsync --info=progress2 gives "  100%  12.3kB/s  0:00:01" lines — reuse draw_bar
    # --outbuf=L line-buffers rsync's own output so progress lines arrive
    # as soon as rsync emits them instead of batching in a stdio buffer.
    args = ["rsync", "-a", "--info=progress2", "--outbuf=L", "-e", _ssh_ctl_opt(target), str(src), dest]
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    buf = ""
    saw_progress = False
    while True:
        chunk = proc.stdout.read(256)
        if not chunk:
            break
        buf += chunk
        while "\r" in buf or "\n" in buf:
            sep_idx = min((i for i in (buf.find("\r"), buf.find("\n")) if i != -1), default=-1)
            if sep_idx == -1:
                break
            line, buf = buf[:sep_idx], buf[sep_idx + 1 :]
            m = RSYNC_PROGRESS_RE.search(line)
            if m:
                saw_progress = True
                draw_bar(name, int(m.group(1)), m.group(2), m.group(3), total_size)
    proc.wait()
    if proc.returncode == 0:
        if not saw_progress:
            # tiny file may not emit progress2 lines — still show 100%
            draw_bar(name, 100, "", "done", total_size)
            print()
        else:
            draw_bar(name, 100, "", "done", total_size)
            print()
    else:
        log_error(f"rsync bootstrap failed (rc={proc.returncode})")
        if saw_progress:
            print()
        return False

    # Make executable
    ssh_chmod = ["ssh", "-o", f"ControlPath={target.control_path}"] + _ssh_extra_opts(target) + [target.ssh, "chmod +x ~/.local/bin/sft && echo ok"]
    proc = subprocess.run(
        ssh_chmod,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or "ok" not in proc.stdout:
        log_warn(f"Copied but chmod +x failed on {target.label}: {proc.stderr.strip()}")

    # Verify
    ssh_verify = ["ssh", "-o", f"ControlPath={target.control_path}"] + _ssh_extra_opts(target) + [target.ssh, "ls -l ~/.local/bin/sft && ~/.local/bin/sft --help 2>&1 | head -n 3"]
    proc = subprocess.run(
        ssh_verify,
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0:
        log_ok(f"sft bootstrapped to {target.label}:~/.local/bin/sft")
        log_dim(proc.stdout.strip()[:400])
        # Hint if ~/.local/bin not on PATH
        ssh_path = ["ssh", "-o", f"ControlPath={target.control_path}"] + _ssh_extra_opts(target) + [target.ssh, "echo $PATH"]
        check = subprocess.run(
            ssh_path,
            capture_output=True,
            text=True,
        )
        if check.stdout and ".local/bin" not in check.stdout:
            log_warn("Remote ~/.local/bin may not be on PATH — add: export PATH=\"$HOME/.local/bin:$PATH\"")
        return True
    else:
        log_ok(f"sft copied to {target.label}:~/.local/bin/sft (verification skipped)")
        return True


def cleanup(target: Target):
    if target and target.owns_master and target.control_path:
        subprocess.run(
            ["ssh", "-O", "exit", "-o", f"ControlPath={target.control_path}", "x"],
            capture_output=True,
        )


# ── shared progress bar renderer ────────────────────────────────────────
_BAR_TICKS = " ▏▎▍▌▋▊▉█"
NAME_WIDTH = 24


def human_size(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def path_size(path):
    """Total bytes of a file, or recursive sum for a directory."""
    if os.path.isdir(path):
        total = 0
        for root, _dirs, files in os.walk(path, followlinks=False):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
        return total
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def _scroll_name(name, width):
    """Marquee-scroll `name` inside `width` columns, paced by wall clock."""
    if len(name) <= width:
        return name.ljust(width)
    gap = "   "
    loop = name + gap
    offset = int(time.monotonic() * 5) % len(loop)
    window = (loop + loop)[offset : offset + width]
    return window


def draw_bar(name, pct, rate="", eta="", total_size=0):
    if _FULLPANE:
        _draw_bar_fullpane(name, pct, rate, eta, total_size)
        return
    width = 30
    pct = max(0, min(100, pct))
    exact = pct * width / 100
    filled = int(exact)
    rem = exact - filled
    tick = _BAR_TICKS[int(rem * (len(_BAR_TICKS) - 1))] if filled < width else ""
    bar = "█" * filled + tick + "░" * (width - filled - len(tick))
    short = _scroll_name(name, NAME_WIDTH)
    if total_size:
        done = human_size(total_size * pct / 100)
        total = human_size(total_size)
        size_str = f"{done}/{total}"
    else:
        size_str = ""
    sys.stdout.write(
        f"\r{short} {C_CYAN}{bar}{C_RESET} {pct:3d}%  {size_str:<14} {rate:<10} {eta:<8}\033[K"
    )
    sys.stdout.flush()


RSYNC_PROGRESS_RE = re.compile(r"(\d+)%\s+([\d.]+[A-Za-z]+/s)\s+([\d:]+)")


# ── full-pane UI (prefix+T) ───────────────────────────────────────────
# Used only by _run_pane_transfer(); direct CLI modes (`sft <alias>` etc.)
# keep the classic single-line prompt/bar above.
_FULLPANE = False


def _term_size():
    sz = shutil.get_terminal_size(fallback=(80, 24))
    return sz.columns, sz.lines


def _alt_screen_enter():
    sys.stdout.write("\033[?1049h\033[?25l")
    sys.stdout.flush()


def _alt_screen_exit():
    sys.stdout.write("\033[?25h\033[?1049l")
    sys.stdout.flush()


def _fullpane_clear():
    sys.stdout.write("\033[H\033[J")


def _fullpane_render(lines, cols=None, rows=None):
    """Clear and redraw the pane with `lines` vertically+horizontally centered."""
    if cols is None or rows is None:
        cols, rows = _term_size()
    _fullpane_clear()
    top_pad = max(0, (rows - len(lines)) // 2)
    out = ["\n"] * top_pad
    for line in lines:
        # strip ANSI color codes when measuring width for centering
        visible = re.sub(r"\033\[[0-9;]*m", "", line)
        pad = max(0, (cols - len(visible)) // 2)
        out.append(" " * pad + line)
    sys.stdout.write("\n".join(out))
    sys.stdout.flush()


def _fullpane_box(title, body_lines, footer=""):
    lines = [f"{C_BOLD}{C_CYAN}{title}{C_RESET}", ""]
    lines += body_lines
    if footer:
        lines += ["", f"{C_DIM}{footer}{C_RESET}"]
    _fullpane_render(lines)


def _draw_bar_fullpane(name, pct, rate="", eta="", total_size=0):
    cols, rows = _term_size()
    width = min(60, max(20, cols - 20))
    pct = max(0, min(100, pct))
    exact = pct * width / 100
    filled = int(exact)
    rem = exact - filled
    tick = _BAR_TICKS[int(rem * (len(_BAR_TICKS) - 1))] if filled < width else ""
    bar = "█" * filled + tick + "░" * (width - filled - len(tick))
    if total_size:
        done = human_size(total_size * pct / 100)
        total = human_size(total_size)
        size_str = f"{done} / {total}"
    else:
        size_str = ""
    lines = [
        f"{C_BOLD}{name}{C_RESET}",
        "",
        f"{C_CYAN}{bar}{C_RESET}",
        f"{pct:3d}%   {size_str}   {rate}   {eta}",
    ]
    _fullpane_render(lines, cols, rows)


def _fullpane_done(name, dst_label):
    _fullpane_box(
        "✓ done",
        [f"{name}", f"{C_DIM}→ {dst_label}{C_RESET}"],
        footer="next file, or q to close",
    )
    time.sleep(0.6)


def _read_one_char():
    """Raw single-keypress read (no echo, no line buffering). Returns
    (char, more_pending) — more_pending is True if more input was already
    sitting in the buffer right behind it (a paste landing multiple chars
    at once), which is how a drag-drop/paste is told apart from a lone
    keypress meant to trigger fzf."""
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        # os.read(), not sys.stdin.read(): the latter is a buffered
        # TextIOWrapper that can silently slurp a paste's remaining bytes
        # into its own userspace buffer, leaving nothing for select() to
        # see as "pending" on the raw fd even though a paste just landed.
        ch = os.read(fd, 1).decode(errors="replace")
        more_pending = bool(select.select([fd], [], [], 0.02)[0])
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    return ch, more_pending


def _fullpane_wait_for_files(dst_label, src_path):
    """Splash screen: drop a file (drag-drop/paste + Enter) or press a key
    to browse with fzf. Returns a list of paths, [] to just redraw/retry,
    or None on quit (q / Ctrl-C / EOF)."""
    have_fzf = bool(shutil.which("fzf"))
    footer = "q to quit"
    if have_fzf:
        footer = "any other key to browse with fzf  •  " + footer
    _fullpane_box(
        "⇅  drop a file here",
        [f"{C_DIM}sending to {dst_label}{C_RESET}", "", "drag & drop, or type a path, then press Enter"],
        footer=footer,
    )
    if not sys.stdin.isatty():
        try:
            line = input()
        except EOFError:
            return None
        return None if line.strip().lower() == "q" else _split_drop(line)
    try:
        ch, more_pending = _read_one_char()
    except (termios.error, OSError):
        try:
            line = input()
        except EOFError:
            return None
        return None if line.strip().lower() == "q" else _split_drop(line)
    if ch == "\x03":
        raise KeyboardInterrupt
    if ch in ("q", "Q") and not more_pending:
        return None
    if ch == "\x1b" and not more_pending:
        # Escape — same as q. (fzf handles its own Escape internally,
        # already treated as "picked nothing" by _pick_files_fzf below.)
        return None
    if ch in ("\r", "\n") and not more_pending:
        return []  # blank Enter — just redraw
    if have_fzf and not more_pending:
        return _pick_files_fzf(src_path)
    # a paste landed (more_pending) or fzf isn't installed — this keypress
    # is the start of a typed/pasted path; read the rest of the line
    try:
        rest = sys.stdin.readline()
    except EOFError:
        rest = ""
    return _split_drop(ch + rest)


def _split_drop(line):
    line = line.strip()
    if not line:
        return []
    try:
        return [os.path.expanduser(p) for p in shlex.split(line) if p]
    except ValueError:
        return [os.path.expanduser(line)]


def _ssh_ctl_opt(target: Target) -> str:
    """Build ssh -o ControlPath=... plus -i / -X if needed for rsync -e string."""
    base = f"ssh -o ControlPath={target.control_path}"
    if getattr(target, "identityfile", ""):
        # -i must be part of the ssh command string for rsync
        base += f" -i {shlex.quote(os.path.expanduser(target.identityfile))}"
    if getattr(target, "x11", "") == "yes":
        base += " -X"
    return base


# ── pane helpers (for prefix+T / --from-pane / --to-pane) ────────────
def _tmux_display(pane_id: str, fmt: str) -> str:
    """Run tmux display -p -t pane_id fmt, return stripped stdout or ''."""
    if not pane_id or not shutil.which("tmux"):
        return ""
    try:
        out = subprocess.run(
            ["tmux", "display", "-p", "-t", pane_id, fmt],
            capture_output=True, text=True, timeout=2
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return ""


def _pane_current_path(pane_id: str) -> str:
    p = _tmux_display(pane_id, "#{pane_current_path}")
    return p if p else ""


def _pane_meta(pane_id: str) -> dict:
    """Return dict with @scpt_remote etc for pane."""
    if not pane_id:
        return {}
    # Use | as delimiter — tmux does not expand \t, and paths rarely contain |
    fmt = "#{@scpt_remote}|#{@scpt_remote_type}|#{@scpt_remote_idf}|#{@scpt_docker_host}|#{pane_current_path}|#{pane_current_command}"
    val = _tmux_display(pane_id, fmt)
    if not val:
        return {}
    parts = val.split("|")
    while len(parts) < 6:
        parts.append("")
    return {
        "remote": parts[0],
        "rtype": parts[1],
        "idf": parts[2],
        "dhost": parts[3],
        "path": parts[4],
        "cmd": parts[5],
    }


# ── name-collision handling ─────────────────────────────────────────
# Never silently overwrite a same-named file/dir already at the
# destination — warn and pick "name (2)", "name (3)", ... instead
# (checked one at a time so it's exact, not a guess).
def _dedupe_name(exists_fn, name):
    """Returns (name_to_use, warning_or_None). exists_fn(candidate) should
    return True if that name is already taken at the destination."""
    if not exists_fn(name):
        return name, None
    base, ext = os.path.splitext(name)
    i = 2
    while True:
        candidate = f"{base} ({i}){ext}"
        if not exists_fn(candidate):
            return candidate, f'"{name}" already exists at the destination — saving as "{candidate}" instead'
        i += 1


def _warn_collision(msg):
    if not msg:
        return
    if _FULLPANE:
        _fullpane_box("⚠  name collision", [msg], footer="continuing…")
        time.sleep(0.9)
    else:
        log_warn(msg)


def _exists_local(dst_dir, name):
    return os.path.exists(os.path.join(dst_dir or str(HOME), name))


def _exists_remote(target: "Target", dst_dir, name):
    path = (dst_dir.rstrip("/") + "/" + name) if dst_dir else f"~/{name}"
    cmd = ["ssh", "-o", f"ControlPath={target.control_path}"] + _ssh_extra_opts(target) + [target.ssh, f"test -e {shlex.quote(path)}"]
    try:
        return subprocess.run(cmd, capture_output=True).returncode == 0
    except Exception:
        return False


def _exists_docker_local(container, dst_dir, name):
    path = (dst_dir.rstrip("/") + "/" + name) if dst_dir else f"/{name}"
    try:
        return subprocess.run(["docker", "exec", container, "test", "-e", path], capture_output=True).returncode == 0
    except Exception:
        return False


def _exists_docker_remote(target: "Target", container, dst_dir, name):
    path = (dst_dir.rstrip("/") + "/" + name) if dst_dir else f"/{name}"
    cmd = ["ssh", "-o", f"ControlPath={target.control_path}"] + _ssh_extra_opts(target) + [target.ssh, f"docker exec {shlex.quote(container)} test -e {shlex.quote(path)}"]
    try:
        return subprocess.run(cmd, capture_output=True).returncode == 0
    except Exception:
        return False


# ── rsync (only) transfers ──────────────────────────────────────────
def transfer_rsync(src: str, target: Target, dst_path: str = "", dedupe: bool = True) -> bool:
    """Rsync src -> target:dst_path. If dst_path empty, uses ~/ (legacy).
    dst_path is taken from pane's current path when run via --to-pane.
    """
    require("rsync")
    name = os.path.basename(src.rstrip("/")) or src
    total_size = path_size(src)
    dst_dir = dst_path.rstrip("/") + "/" if dst_path else "~/"
    if dedupe:
        name, warn = _dedupe_name(lambda n: _exists_remote(target, dst_path, n), name)
        _warn_collision(warn)
    dst_spec = f"{target.ssh}:{dst_dir}{name}"
    args = ["rsync", "-a", "--info=progress2", "--outbuf=L", "-e", _ssh_ctl_opt(target)]
    if os.path.isdir(src):
        args.append("-r")
    args += [src, dst_spec]

    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    buf = ""
    while True:
        chunk = proc.stdout.read(256)
        if not chunk:
            break
        buf += chunk
        while "\r" in buf or "\n" in buf:
            sep_idx = min((i for i in (buf.find("\r"), buf.find("\n")) if i != -1), default=-1)
            if sep_idx == -1:
                break
            line, buf = buf[:sep_idx], buf[sep_idx + 1:]
            m = RSYNC_PROGRESS_RE.search(line)
            if m:
                draw_bar(name, int(m.group(1)), m.group(2), m.group(3), total_size)
    proc.wait()
    if proc.returncode == 0:
        draw_bar(name, 100, "", "done", total_size)
        print()
        return True
    # print last error for diagnostics
    log_warn(f"rsync failed for {name} (rc={proc.returncode})")
    return False


def transfer_local_rsync(src: str, dst_dir: str) -> bool:
    """Local -> local rsync (used for pane local->local). dst_dir from pane."""
    require("rsync")
    name = os.path.basename(src.rstrip("/")) or src
    total_size = path_size(src)
    if not dst_dir:
        dst_dir = str(Path.home())
    dst_dir = dst_dir.rstrip("/") + "/"
    name, warn = _dedupe_name(lambda n: _exists_local(dst_dir, n), name)
    _warn_collision(warn)
    args = ["rsync", "-a", "--info=progress2", "--outbuf=L", src, dst_dir + name]
    if os.path.isdir(src):
        # -a already handles dirs, but keep
        pass
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    buf = ""
    while True:
        chunk = proc.stdout.read(256)
        if not chunk:
            break
        buf += chunk
        while "\r" in buf or "\n" in buf:
            sep_idx = min((i for i in (buf.find("\r"), buf.find("\n")) if i != -1), default=-1)
            if sep_idx == -1:
                break
            line, buf = buf[:sep_idx], buf[sep_idx + 1:]
            m = RSYNC_PROGRESS_RE.search(line)
            if m:
                draw_bar(name, int(m.group(1)), m.group(2), m.group(3), total_size)
    proc.wait()
    if proc.returncode == 0:
        draw_bar(name, 100, "", "done", total_size)
        print()
        return True
    log_warn(f"rsync local failed (rc={proc.returncode})")
    return False


def transfer_docker(src: str, container: str, dst_dir: str = "", rhost: str = "") -> bool:
    """Local -> docker via `docker cp` (only exception to rsync rule).
    If rhost given, docker is on remote host: first rsync to rhost then docker cp there.
    """
    if not src or not container:
        log_error("docker transfer needs src and container")
        return False
    name = os.path.basename(src.rstrip("/")) or src
    # If remote docker, first stage to remote host
    if rhost:
        # Stage file to remote ~/ via rsync, then remote docker cp
        # Use ephemeral target for staging
        tmp_target = Target()
        tmp_target.label = tmp_target.ssh = rhost
        # Try lookup for identity/x11
        hit = lookup_host(rhost) if "@" not in rhost and alias_exists(rhost) else None
        if hit:
            _h, _u, _idf, _x11 = hit
            tmp_target.ssh = f"{_u}@{_h}" if _u and _h else rhost
            tmp_target.identityfile = _idf or ""
            tmp_target.x11 = _x11 or ""
        # Need control master for rhost
        # If we already have active CM, reuse?
        active = {uh: sock for uh, _, _, sock in list_active_ssh()}
        if rhost in active:
            tmp_target.control_path = active[rhost]
            tmp_target.owns_master = False
        else:
            warm_control_master(tmp_target)
            # will be cleaned by caller? but we need to keep for second step
        # Dedupe against the actual container destination, not the staging
        # dir (staging is a private scratch area — no need to dedupe there).
        dst = dst_dir.rstrip("/") + "/" if dst_dir else "/root/"
        final_name, warn = _dedupe_name(lambda n: _exists_docker_remote(tmp_target, container, dst_dir, n), name)
        _warn_collision(warn)
        # Ensure staging via rsync to remote (own name — no dedupe needed here)
        if not transfer_rsync(src, tmp_target, "~/.sft-docker-stage/", dedupe=False):
            if tmp_target.owns_master:
                cleanup(tmp_target)
            return False
        # Now docker cp on remote — stage held it under the original name,
        # copy it into the container under the (possibly deduped) final name.
        ssh_base = ["ssh", "-o", f"ControlPath={tmp_target.control_path}"] + _ssh_extra_opts(tmp_target) + [tmp_target.ssh]
        remote_cmd = f"docker cp ~/.sft-docker-stage/{shlex.quote(name)} {shlex.quote(container)}:{shlex.quote(dst + final_name)} && echo ok"
        proc = subprocess.run(ssh_base + [remote_cmd], capture_output=True, text=True)
        if tmp_target.owns_master:
            cleanup(tmp_target)
        if proc.returncode == 0 and "ok" in proc.stdout:
            log_ok(f"Copied {final_name} → {container}:{dst} (via {rhost})")
            return True
        log_error(f"docker cp on {rhost} failed: {proc.stderr.strip()}")
        return False

    # Local docker
    if not shutil.which("docker"):
        log_error("docker not installed for docker cp")
        return False
    # Ensure container exists
    exists = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}"], capture_output=True, text=True)
    if container not in (exists.stdout or ""):
        log_warn(f"container {container} not in docker ps -a")
    dst = dst_dir.rstrip("/") + "/" if dst_dir else "/"
    name, warn = _dedupe_name(lambda n: _exists_docker_local(container, dst_dir, n), name)
    _warn_collision(warn)
    # docker cp handles file and dir differently; for dir need src with trailing .
    # Use `docker cp src container:dst`
    # For dir, use `docker cp src/. container:dst`? Use plain
    cmd = ["docker", "cp", src, f"{container}:{dst}{name}"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode == 0:
        # Show 100% bar for UX consistency
        total_size = path_size(src)
        draw_bar(name, 100, "", "done", total_size)
        print()
        log_ok(f"Copied {name} → {container}:{dst}")
        return True
    log_error(f"docker cp failed: {proc.stderr.strip()}")
    return False


def transfer_one(src: str, target: Target, dst_path: str = ""):
    """Legacy single-target path (~/ if dst_path empty). Rsync only."""
    if not os.path.exists(src):
        log_error(f"Not found: {src}")
        return False
    ok = transfer_rsync(src, target, dst_path)
    if ok:
        dest = dst_path if dst_path else "~/"
        log_ok(f"Copied {os.path.basename(src)} → {target.label}:{dest}")
        return True
    else:
        log_error(f"Failed to copy {src}")
        return False


def _pick_files_fzf(src_dir: str):
    """Run fzf on files under src_dir, return list. Empty if fzf missing/cancel."""
    if not shutil.which("fzf") or not src_dir or not os.path.isdir(src_dir):
        return []
    try:
        # Find files up to depth 4, avoid huge walk
        find_cmd = ["find", src_dir, "-maxdepth", "4", "-type", "f", "-print"]
        # Use fzf multi-select
        fzf_cmd = ["fzf", "-m", "--height=80%", "--prompt=file › ", "--reverse", "--preview", "ls -lh {} 2>/dev/null | head -20"]
        p1 = subprocess.Popen(find_cmd, stdout=subprocess.PIPE, text=True)
        p2 = subprocess.Popen(fzf_cmd, stdin=p1.stdout, stdout=subprocess.PIPE, text=True)
        p1.stdout.close()
        out, _ = p2.communicate()
        p1.wait()
        if p2.returncode != 0 or not out.strip():
            return []
        files = [line.strip() for line in out.strip().splitlines() if line.strip()]
        return files
    except Exception:
        return []


def _run_pane_transfer(src_pane: str, to_pane: str = "", to_alias: str = "", to_docker: str = "", docker_host: str = ""):
    """Full-pane transfer for prefix+T: always src_pane == to_pane (the
    current pane calls this on itself) — destination is whatever this pane
    is already connected to. Dest path is that pane's current path (or ~/
    when invoked via --to-alias/--to-docker directly, without a pane).
    Uses rsync for all except docker cp exception.
    """
    src_path = _pane_current_path(src_pane) if src_pane else ""
    if not src_path:
        src_path = os.getcwd()
    log_info(f"Source pane {src_pane} @ {src_path}")

    dst_path = ""
    dst_label = ""
    target = None

    # Resolve destination
    if to_pane:
        meta = _pane_meta(to_pane)
        dst_path = meta.get("path") or ""
        remote = meta.get("remote") or ""
        rtype = meta.get("rtype") or ""
        dhost = meta.get("dhost") or ""
        if rtype == "docker":
            # local->docker (pane is docker)
            to_docker = remote
            docker_host = dhost
            dst_path = dst_path or "/"
            dst_label = f"{to_docker}:{dst_path}"
        elif rtype in ("alias", "ephemeral") and remote:
            to_alias = remote
            # dst_path from pane
            dst_label = f"{to_alias}:{dst_path}"
            target = resolve_target_for_alias(to_alias)
            # override target dst to pane path (not ~/)
        elif not remote:
            # local pane -> local
            dst_label = f"local:{dst_path}"
            # no ssh target needed
        else:
            dst_label = f"{remote}:{dst_path}"
    elif to_alias:
        target = resolve_target_for_alias(to_alias)
        dst_path = ""  # will use pane logic? when via alias not pane, use ~/ fallback — but caller should have provided to_pane
        # For alias without pane, we keep ~/ semantics? But spec says always pane path; here no pane so use ~/
        dst_label = f"{to_alias}:~/"
        if target and hasattr(target, 'control_path') is False:
            pass
    elif to_docker:
        dst_label = f"{to_docker}:{dst_path or '/'}"
        dst_path = dst_path or "/"
    else:
        log_error("No destination resolved")
        sys.exit(1)

    # Prepare ssh target if needed and not already
    if to_alias and target is None:
        target = resolve_target_for_alias(to_alias)

    # Tool requirements depend on the destination — a docker-only host
    # with no ssh/rsync installed can still drop files into a LOCAL
    # container (docker cp needs neither); only remote destinations
    # (ssh alias, or docker on a remote host, which stages via rsync
    # over ssh first) need rsync/ssh at all.
    if to_docker:
        if docker_host:
            require("rsync")
            require("ssh")
        else:
            require("docker")
    elif target:
        require("rsync")
        require("ssh")
    else:
        require("rsync")

    # One transfer function per destination kind — the full-pane splash/
    # progress loop below is identical either way.
    if to_docker:
        def do_transfer(f):
            return transfer_docker(f, to_docker, dst_path, docker_host)
    elif target:
        effective_dst = dst_path if dst_path else ""
        def do_transfer(f):
            return transfer_one(f, target, effective_dst)
    else:
        def do_transfer(f):
            return transfer_local_rsync(f, dst_path)

    global _FULLPANE
    _FULLPANE = True
    _alt_screen_enter()
    try:
        while True:
            files = _fullpane_wait_for_files(dst_label, src_path)
            if files is None:
                break
            for f in files:
                name = os.path.basename(f.rstrip("/")) or f
                do_transfer(f)
                _fullpane_done(name, dst_label)
    except KeyboardInterrupt:
        pass
    finally:
        _FULLPANE = False
        _alt_screen_exit()
        if target:
            cleanup(target)
        return


def print_usage():
    prog = os.path.basename(sys.argv[0]) or "sft"
    print(f"{C_BOLD}Usage:{C_RESET} {prog} [options] [alias] [FILE...]")
    print("")
    print(f"  {C_BOLD}(no args){C_RESET}              Interactive file drop copier (default)")
    print(f"  {C_CYAN}<alias> <FILE...>{C_RESET}      Copy FILE(s) to remote alias's ~/ (supports key, keyfile, password)")
    print(f"  {C_CYAN}<alias>{C_RESET}                Interactive copier to that alias (no pick)")
    print(f"  {C_CYAN}-l, --list{C_RESET}             List remote aliases and active connections")
    print(f"  {C_CYAN}--from-pane <id> --to-pane <id>{C_RESET}  Full-pane transfer (prefix+T): dest = that pane's own connection")
    print(f"  {C_CYAN}--to-alias <alias>{C_RESET}     Pane-aware to saved remote (rare)")
    print(f"  {C_CYAN}--to-docker <name> [--docker-host <host>]{C_RESET}  Pane-aware to docker (exception: docker cp)")
    print(f"  {C_CYAN}-b, --bootstrap{C_RESET}        Copy sft itself to remote ~/.local/bin/sft")
    print(f"                             Uses same target picking as normal mode, or")
    print(f"                             give a host directly: {prog} -b user@host")
    print(f"  {C_CYAN}-h, --help{C_RESET}             Show this help")
    print("")
    print(f"{C_DIM}Transfer:{C_RESET} rsync required (no scp fallback). Dest path = target pane's current path")
    print(f"  when invoked via --from-pane/--to-pane (prefix+T). Direct `sft <alias> <FILE>` still uses ~/ .")
    print(f"  docker is the only exception (docker cp). fzf picks files, drag-drop still works.")
    print(f"{C_DIM}Auth:{C_RESET} 3 methods — SSH key/agent (default), keyfile via IdentityFile (e.g. AWS .pem),")
    print(f"  and password (ssh prompts, then ControlMaster reuses). All work with `sft <alias> <FILE>`")
    print(f"  and pane transfers. Saved hosts shared with scpt via {MARKER}.")
    print(f"{C_DIM}Host storage:{C_RESET} saved hosts live in ~/.ssh/config when writable,")
    print(f"  otherwise in {FALLBACK_SSH_CONFIG} (shared with scpt) — ~/.ssh perms")
    print(f"  are never changed.")
    print(f"{C_DIM}Note:{C_RESET} -r is aliased to -l for compatibility.")


def main():
    # ── arg parse (keep minimal, no argparse to avoid extra deps) ────────
    bootstrap_mode = False
    bootstrap_host = None
    show_help = False
    list_mode = False
    from_pane = ""
    to_pane = ""
    to_alias = ""
    to_docker = ""
    docker_host = ""
    positionals = []
    unknown = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-b", "--bootstrap"):
            bootstrap_mode = True
        elif a in ("-l", "-r", "--list", "--remotes"):
            list_mode = True
        elif a in ("-h", "--help"):
            show_help = True
        elif a == "--from-pane":
            if i + 1 < len(args):
                from_pane = args[i+1]; i+=1
            else:
                unknown = a
                break
        elif a == "--to-pane":
            if i + 1 < len(args):
                to_pane = args[i+1]; i+=1
            else:
                unknown = a
                break
        elif a == "--to-alias":
            if i + 1 < len(args):
                to_alias = args[i+1]; i+=1
            else:
                unknown = a
                break
        elif a == "--to-docker":
            if i + 1 < len(args):
                to_docker = args[i+1]; i+=1
            else:
                unknown = a
                break
        elif a == "--docker-host":
            if i + 1 < len(args):
                docker_host = args[i+1]; i+=1
            else:
                unknown = a
                break
        elif a.startswith("-"):
            unknown = a
            break
        else:
            positionals.append(a)
        i+=1
    if show_help:
        print_usage()
        sys.exit(0)
    if unknown is not None:
        log_error(f"Unknown argument: {unknown}")
        print_usage()
        sys.exit(1)
    if list_mode:
        # sft -l (and -r alias) lists remote aliases + active connections, no ssh needed? but check
        print_remotes()
        sys.exit(0)
    # Pane-aware transfer (prefix+T) — dst pane path always, ~/ only for direct sft
    if from_pane or to_pane or to_alias or to_docker:
        # Normalize: if from_pane given but no dst, error
        if from_pane and not (to_pane or to_alias or to_docker):
            log_error("--from-pane needs --to-pane / --to-alias / --to-docker")
            sys.exit(1)
        # to_pane takes precedence over alias/docker if both given (menu sets one)
        # When to_pane is local pane, use local rsync; when to_alias/docker, use that
        # If from_pane not given but to_* given, assume src is current pane
        if not from_pane and (to_pane or to_alias or to_docker):
            from_pane = _tmux_display("", "#{pane_id}")  # fallback empty
            # try to get active pane via tmux
            try:
                from_pane = subprocess.run(["tmux", "display", "-p", "#{pane_id}"], capture_output=True, text=True, timeout=1).stdout.strip() or ""
            except Exception:
                from_pane = ""
        try:
            _run_pane_transfer(from_pane, to_pane, to_alias, to_docker, docker_host)
            sys.exit(0)
        except KeyboardInterrupt:
            print()
            log_info("Cancelled.")
            sys.exit(130)
        except SystemExit:
            raise
        except Exception as e:
            log_error(str(e))
            sys.exit(1)
    # Bootstrap host handling: `sft -b [host]` — if positionals given in bootstrap mode
    if bootstrap_mode:
        if positionals:
            bootstrap_host = positionals[0]
            if len(positionals) > 1:
                log_warn(f"Ignoring extra args after bootstrap host: {positionals[1:]}")
        # fall through to bootstrap handling below (after require)
    else:
        # Direct copy mode: `sft <alias> <FILE...>` or `sft <alias>` (interactive to alias)
        # Also handle `sft <user@host> <FILE...>` as raw host.
        if len(positionals) >= 2:
            # sft <alias> <FILE...>
            alias = positionals[0]
            files = positionals[1:]
            require("ssh")
            require("rsync")
            target = None
            old_settings = None
            if sys.stdin.isatty():
                try:
                    old_settings = termios.tcgetattr(sys.stdin.fileno())
                except termios.error:
                    old_settings = None
            try:
                target = resolve_target_for_alias(alias)
                failed = False
                for f in files:
                    fp = os.path.expanduser(f)
                    if not os.path.exists(fp):
                        log_error(f"Not found: {f}")
                        failed = True
                        continue
                    transfer_one(fp, target)
                    # transfer_one logs success/failure; track failure if needed
                sys.exit(1 if failed else 0)
            except KeyboardInterrupt:
                print()
                log_info("Cancelled.")
                sys.exit(130)
            except SystemExit:
                raise
            except Exception as e:
                log_error(str(e))
                sys.exit(1)
            finally:
                if old_settings is not None:
                    try:
                        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_settings)
                    except termios.error:
                        pass
                try:
                    cleanup(target)
                except Exception:
                    pass
            return
        elif len(positionals) == 1:
            # sft <alias>  — interactive mode pinned to that alias (skip picker)
            alias = positionals[0]
            require("ssh")
            require("rsync")
            old_settings = None
            if sys.stdin.isatty():
                try:
                    old_settings = termios.tcgetattr(sys.stdin.fileno())
                except termios.error:
                    old_settings = None
            target = None
            try:
                target = resolve_target_for_alias(alias)
                print()
                log_info("Ready. Drag a file or folder into this window and press enter.")
                log_dim(f"  (q or Ctrl-C to quit — connected to {target.label})")
                print()
                while True:
                    try:
                        line = input(f"{C_MAGENTA}drop ›{C_RESET} ")
                    except EOFError:
                        print()
                        break
                    line = line.strip()
                    if not line:
                        continue
                    if line.lower() == "q":
                        break
                    try:
                        dropped = shlex.split(line)
                    except ValueError:
                        dropped = [line]
                    for f in dropped:
                        if f:
                            transfer_one(os.path.expanduser(f), target)
                log_info("Bye.")
                sys.exit(0)
            except KeyboardInterrupt:
                print()
                log_info("Bye.")
                sys.exit(0)
            except SystemExit:
                raise
            finally:
                if old_settings is not None:
                    try:
                        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_settings)
                    except termios.error:
                        pass
                try:
                    cleanup(target)
                except Exception:
                    pass
            return

    require("ssh")

    # ── bootstrap mode ────────────────────────────────────────────────
    if bootstrap_mode:
        old_settings = None
        if sys.stdin.isatty():
            try:
                old_settings = termios.tcgetattr(sys.stdin.fileno())
            except termios.error:
                old_settings = None
        target = None
        try:
            if bootstrap_host:
                target = Target()
                target.label = bootstrap_host
                # If bootstrap_host is a fallback-only alias, resolve to user@host
                hit = lookup_host(bootstrap_host) if "@" not in bootstrap_host else None
                if hit and not alias_in_ssh_config(bootstrap_host):
                    _h, _u, _idf, _x11 = hit
                    target.ssh = f"{_u}@{_h}" if _u and _h else bootstrap_host
                    target.identityfile = _idf or ""
                    target.x11 = _x11 or ""
                    log_dim(f"(host '{bootstrap_host}' from fallback {FALLBACK_SSH_CONFIG} — using {target.ssh})")
                else:
                    target.ssh = bootstrap_host
                warm_control_master(target)
            else:
                target = resolve_target()
            ok = bootstrap_self(target)
            sys.exit(0 if ok else 1)
        except KeyboardInterrupt:
            print()
            log_info("Cancelled.")
            sys.exit(130)
        finally:
            if old_settings is not None:
                try:
                    termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_settings)
                except termios.error:
                    pass
            cleanup(target)
        return

    # ── normal drag-and-drop mode ─────────────────────────────────────
    old_settings = None
    if sys.stdin.isatty():
        old_settings = termios.tcgetattr(sys.stdin.fileno())

    target = None
    try:
        target = resolve_target()
        print()
        log_info("Ready. Drag a file or folder into this window and press enter.")
        log_dim(f"  (q or Ctrl-C to quit — connected to {target.label})")
        print()

        while True:
            try:
                line = input(f"{C_MAGENTA}drop ›{C_RESET} ")
            except EOFError:
                print()
                break
            line = line.strip()
            if not line:
                continue
            if line.lower() == "q":
                break
            try:
                dropped = shlex.split(line)
            except ValueError:
                dropped = [line]
            for f in dropped:
                if f:
                    transfer_one(os.path.expanduser(f), target)
        log_info("Bye.")
    except KeyboardInterrupt:
        print()
        log_info("Bye.")
    finally:
        if old_settings is not None:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_settings)
        cleanup(target)


if __name__ == "__main__":
    main()
