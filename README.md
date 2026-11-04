# scpt

> A single-file `bash` helper for `tmux` — pick an SSH host, Docker container, or local shell from a menu and connect in the current pane. No `~/.tmux.conf` edits required.

Run it inside tmux to show the menu. Outside tmux it bootstraps a `main` session and binds itself to `prefix+c`.

```sh
./scpt.sh              # show menu in current tmux session
./scpt.sh --bind       # install prefix+c → smart menu (this server only)
./scpt.sh --unbind     # restore prefix+c → new-window
```

---

## Preview

| Connection menu (`prefix+c`) | Fuzzy pane picker (`prefix+f`) |
|---|---|
| ![Connection menu](assets/Screenshot%20from%202026-08-25%2014-24-59.png) | ![Pane picker](assets/Screenshot%20from%202026-08-25%2014-24-34.png) |

*Left: `prefix+c` — connect to this machine, saved SSH hosts, active Docker containers, or add a new remote. Right: `prefix+f` — `fzf` window/pane picker with live preview (falls back to `choose-tree` without `fzf`).*

---

## Quick Start

```sh
# 1. Clone / copy somewhere on PATH
git clone https://github.com/davidnoronha1/scpt.git ~/bin/scpt
chmod +x ~/bin/scpt/scpt.sh

# 2. Inside tmux, install the smart bindings (current server only)
~/bin/scpt/scpt.sh --bind

# 3. Hit prefix+c to open the menu
# 4. Optional: auto-bind on every new tmux server
echo '[ -n "$TMUX" ] && ~/bin/scpt/scpt.sh --bind >/dev/null' >> ~/.bashrc
```

Outside tmux, just run `~/bin/scpt/scpt.sh` — it creates/attaches to session `main` for you.

---

## How it works

### Host storage — just `~/.ssh/config`

Hosts you add via scpt are written as normal `Host` blocks in `~/.ssh/config` (marked with `# tmux-remote-helper`), so they work with plain `ssh <alias>` too:

```
# tmux-remote-helper
Host robopc
    HostName 192.168.0.116
    User david
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

Only blocks scpt wrote are shown in the menu — your other entries (e.g. `github.com`) are left alone. If `~/.ssh/config` isn't writable, scpt falls back to `~/.config/scpt/hosts` (shared with `sft`).

### The menu

Inside tmux (or via `prefix+c` once bound):

- **This machine** — local shell
- **Saved remotes** — every host scpt added to `~/.ssh/config`
- **Active SSH** — existing `ControlMaster` sockets (reused, no re-auth)
- **Docker containers** — `docker ps` on this machine (or on the remote you're currently SSH'd into)
- **+ Add new remote** — prompts for alias, host/IP, user, keyfile/password, X11
- **+ Scan network (nmap)** — finds devices on your subnet and lets you add one

### Auth

- **SSH key / agent** (default)
- **Specific keyfile** via `IdentityFile` (e.g. AWS `.pem`)
- **Password** — `ssh` prompts in-pane, nothing stored. After adding a password host, scpt offers to run `ssh-copy-id` so next time is passwordless.

Every managed host gets `ControlMaster`/`ControlPersist`, so repeated connects — including `sft` transfers and splits — share one underlying connection.

---

## Keybindings (`--bind`)

`./scpt.sh --bind` installs smart, multiplexed bindings on the **current tmux server** only. `./scpt.sh --unbind` restores tmux defaults.

| Binding | Action |
|---|---|
| `prefix+c` | **Smart new window** — if pane is an scpt SSH/Docker connection, opens a new window to the *same* target (reuses `ControlMaster`); otherwise shows the connection menu |
| `prefix+C` | Always show the connection menu |
| `prefix+%` / `prefix+"` | **Smart splits** — same multiplexing as above, vertical/horizontal |
| `prefix+T` | File transfer popup for the current pane (via `sft`) |
| `prefix+R` | Reconnect current pane in-place if the connection dropped |
| `prefix+f` | `fzf` window/pane picker with preview (falls back to `choose-tree`) |
| `Right-click` | Copies selection if there is one, otherwise shows Paste / Split / Zoom / Kill menu. Panes running `claude`/`opencode`/`gemini`/`nvim` (or `mouse_any_flag`) always show the menu — those apps own their mouse/clipboard, so tmux stays out of the way and avoids double-copy |

> **Remote persistence:** if scpt is installed on the remote, you get a persistent remote `tmux` session per local pane (`scpt-brave-otter-3` etc.). Set `SCPT_REMOTE_TMUX=0` to force plain `ssh` instead.

---

## Companion: `sft` — drag-and-drop file transfer

`sft/sft.py` reuses the same hosts and `ControlMaster` connections as `scpt.sh` — no separate config, no re-auth.

```sh
sft/sft.py              # interactive: pick target, drag files/folders, Enter to send to ~/
sft/sft.py -b [host]    # bootstrap: copy sft to remote's ~/.local/bin
```

Transfers use `rsync --info=progress2` with a progress bar. In tmux, `prefix+T` opens `sft` as a full-pane popup scoped to the current pane.

---

## Extras

### X11 forwarding

You're asked when adding a host. Persisted as `ForwardX11`/`ForwardX11Trusted` in `~/.ssh/config` for saved hosts, or just `-X` for one-off connections.

### Persisting tmux tweaks

scpt applies its mouse / color / copy-behavior / statusline tweaks **live** only to servers it bootstraps or you run `--bind` in — it never writes to `~/.tmux.conf`.

To make them permanent for *every* tmux server:

```sh
./scpt.sh --persist >> ~/.tmux.conf
```

---

## Requirements

| Required | Optional |
|---|---|
| `bash`, `tmux`, `ssh` | `fzf` (nicer pickers), `nmap` (network scan), `rsync` (sft), `docker` (container support) |

If your terminal's colors look wrong, check `echo $TERM` / `tput colors` — scpt expects at least 256-color / truecolor (`TERM=xterm-256color`, `COLORTERM=truecolor`).

---

## Command reference

```sh
./scpt.sh --help
./scpt.sh -l            # list tmux sessions, panes, docker containers, saved remotes, active ControlMasters
./scpt.sh --add         # add a host non-interactively (prompts)
./scpt.sh --scan        # nmap scan and add
```

See `scpt.sh` header comments for full details.
