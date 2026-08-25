# scpt

A tmux-based SSH/Docker connection helper, self-contained in a single bash
script — no edits to `~/.tmux.conf` required (see [Persisting tmux
settings](#persisting-tmux-settings) if you want them anyway).

Run it inside tmux and it shows a menu of your saved SSH hosts, active Docker
containers, and this machine — pick one and it connects in the current pane.
Outside tmux, it bootstraps a session and binds itself to `prefix+c`.

```
./scpt.sh              # shows menu in current tmux session
./scpt.sh --bind        # installs prefix+c → menu (this server only)
./scpt.sh --unbind      # restores prefix+c → new-window
```

Host storage lives in `~/.ssh/config` itself, as normal `Host` blocks (marked
with a `# tmux-remote-helper` comment), not a private file — so hosts you add
here also work with plain `ssh <alias>` outside of tmux, and the menu just
reflects whatever's in your config. Only entries scpt wrote are shown in the
menu, so your other, unrelated `~/.ssh/config` entries aren't dumped into the
list.

## Menu

Inside tmux (or via `prefix+c` once bound), the menu shows:

- This machine
- ...every host scpt has added to `~/.ssh/config`...
- **+ Add new remote** — prompts for alias, host/IP, user, key/keyfile/password
- **+ Scan network (nmap)** — finds devices on the subnet, lets you add one

Docker containers running on any connected host are also reachable from the
menu.

## Auth

SSH key/agent (default), a specific keyfile (e.g. an AWS `.pem`, via
`IdentityFile`), or password (ssh just prompts in the pane — nothing is
stored). Right after adding a password-auth host, scpt offers to run
`ssh-copy-id` so future connects are passwordless — after that, plain
`ssh <alias>` picks up the key automatically, no config rewrite needed.

Each managed host also gets `ControlMaster`/`ControlPersist` lines, so
repeated connects to it share one underlying SSH connection — including
across `sft` transfers and new panes/windows.

## Smart splits & keybindings (`--bind`)

```
./scpt.sh --bind
```

Installs:

- `prefix+c` — smart new window: if the current pane is an scpt SSH/Docker
  connection, opens a new window connected to the *same* target (reusing the
  ControlMaster connection, no re-auth); otherwise opens a plain local window.
- `prefix+C` — always shows the menu.
- `prefix+%` / `prefix+"` — smart splits, same multiplexing behavior as above.
- `prefix+T` — full-pane file transfer: drop a file (or use fzf) to send it to
  wherever the current pane is connected.
- `prefix+R` — reconnects the current pane in place if its connection dropped.
- `prefix+f` — fzf-powered window/pane picker (falls back to `choose-tree`).
- Right-click — copies the current selection directly if there is one,
  otherwise shows a small menu (Paste/Split/Zoom/Kill). Panes running
  `claude`/`opencode`/`gemini`/`nvim` (or anything else that's grabbed mouse
  reporting) always get the menu instead — those apps handle their own
  mouse-drag selection and clipboard, so tmux stays out of the way instead of
  copying a second time.

Remote tmux is used by default for persistence when scpt is installed on the
remote host — set `SCPT_REMOTE_TMUX=0` to force plain ssh instead (no remote
persistence).

`./scpt.sh --unbind` restores all of the above to tmux's defaults.

To auto-install the binding whenever you start tmux, add to `~/.bashrc` /
`~/.zshrc`:

```sh
[ -n "$TMUX" ] && ~/bin/scpt.sh --bind >/dev/null
```

## Persisting tmux settings

scpt applies its mouse/color/copy-behavior/statusbar tweaks live, only to
tmux servers it actually bootstraps or that you run `--basics` in — it never
writes to `~/.tmux.conf`, so unrelated tmux usage on the same machine is
unaffected.

If you'd rather have these survive in every tmux server regardless, print
them and redirect yourself:

```sh
./scpt.sh --persist >> ~/.tmux.conf
```

## X11 forwarding

When adding a host you're asked whether to enable X11 forwarding — persisted
as `ForwardX11`/`ForwardX11Trusted` in `~/.ssh/config` for saved hosts, or
just `-X` for one-off connections.

## sft — drag-and-drop file transfer

`sft/sft.py` is a companion tool: run it, pick (or type) a remote target, then
drag files/folders into the terminal and press enter to copy them to `~/` on
the remote with a progress bar (via `rsync --info=progress2`). It reuses the
same ControlMaster connections and host storage as `scpt.sh`, so no re-auth
and no separate config.

```sh
sft/sft.py            # interactive
sft/sft.py -b [host]  # bootstrap: copy sft itself to the remote's ~/.local/bin
```

## Requirements

`bash`, `tmux`, `ssh`. Optional: `fzf` (picker popup, nicer list views),
`nmap` (network scan), `rsync` (sft transfers), `docker` (container support).

## Full command reference

```
./scpt.sh --help
```
