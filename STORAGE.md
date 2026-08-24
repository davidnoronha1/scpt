# Config file & persistence — how to approach it

(Not implemented yet — this is the design guidance for a future pass, written
down so it doesn't need to be re-derived later.)

The goal: a config file that, when run, launches tmux with a specific saved
layout of connections/panes (local/remote/docker), plus a way for
sessions/connections to persist across restarts.

## Declarative layout file, not a shell script to hand-maintain

e.g. YAML/TOML/simple line-based format listing windows/panes and what each
should connect to — `local`, `alias:host`, `docker:container[@host]` — plus
tmux layout hints (split direction/sizes) if you want more than one pane per
window. A "launcher" script reads this file and, for each entry, calls the
same `scpt.sh --connect <alias>` / `--connect-docker <name> <ctx>` functions
that already exist, into new windows/panes of a named tmux session — so the
launcher is thin glue over functionality that's already implemented, not a
new connection engine.

## Where it lives

`~/.config/scpt/sessions/<name>.conf` (or `.yaml`), one file per saved
layout, alongside the already-existing `~/.config/scpt/hosts` — keeps all
scpt state under one directory. A `scpt --launch <name>` command creates (or
attaches to, if already running) a tmux session built from that file.

## Persistence of connection state

This is mostly already free: ControlMaster sockets (`~/.ssh/cm-*`) already
survive across scpt invocations for `ControlPersist 10m`, and remote tmux
sessions (now the default — see scpt.sh's `connect()`) persist independently
of your local tmux — so "reconnecting" a saved layout mostly means re-running
the same connect calls, which will transparently reuse the still-warm
ControlMaster socket / reattach to the still-running remote tmux session
rather than doing fresh auth or losing remote state.

The main new persistence concern is *local* tmux session survival (if the
machine reboots, local tmux state is gone) — for that, evaluate an existing
tool (`tmux-resurrect`/`tmux-continuum`) rather than building
session-serialization from scratch, since scpt's job is connection
management, not general tmux session persistence.

## Auto-launch on boot/login

If wanted later, this is just "run `scpt --launch <name>`" from cron/systemd
--user/shell rc — no special support needed inside scpt itself beyond the
`--launch` entry point.

## Sequencing

Treat this as its own follow-up plan once the rename, remote-tmux-by-default,
prefix+T full-pane transfer, and prefix+R reload work is solid, since the
launcher's design should build on that behavior rather than be designed
against the old defaults.
