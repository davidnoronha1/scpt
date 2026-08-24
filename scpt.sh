#!/usr/bin/env bash
# scpt.sh
#
# Self-contained — no edits to ~/.tmux.conf, and host storage now lives
# in ~/.ssh/config itself (as normal `Host` blocks), not a private file.
# That means hosts you add here also work with plain `ssh <alias>`
# outside of tmux, and the menu just reflects whatever's in your config.
#
# Run inside tmux to show the menu (no binding by default):
#     ./scpt.sh              # shows menu in current tmux session
#     ./scpt.sh --bind       # installs prefix+c → menu (this server only)
#     ./scpt.sh --unbind     # restores prefix+c → new-window
# Outside tmux it auto-launches tmux session 'main' and binds there.
#
# The menu (inside tmux or via prefix+c if bound) shows:
#   - This machine
#   - ...every host this script has added to ~/.ssh/config...
#   - + Add new remote        (alias, host/IP, user, key/keyfile/password)
#   - + Scan network (nmap)   (finds devices, lets you add one)
#
# Only entries this script wrote are shown in the menu (marked with a
# "# tmux-remote-helper" comment line above the Host block), so your
# other, unrelated ~/.ssh/config entries (github.com etc.) aren't
# dumped into the list.
#
# Auth: SSH key/agent (default), a specific keyfile (e.g. AWS .pem, via
# IdentityFile), or password (ssh just prompts in the pane — nothing
# stored). Right after adding a password-auth host, it offers to run
# ssh-copy-id so future connects to it are passwordless — after that,
# plain `ssh <alias>` picks up the key automatically, no config
# rewrite needed.
#
# Each managed host also gets ControlMaster/ControlPersist lines, so
# repeated connects to it share one underlying SSH connection.
#
# Optional: to have the binding auto-install whenever you start tmux,
# add this line to ~/.bashrc / ~/.zshrc (a shell rc file, not tmux.conf):
#   [ -n "$TMUX" ] && ~/bin/scpt.sh >/dev/null

set -uo pipefail

SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
THIS_HOST="$(hostname -s)"
SSH_CONFIG="$HOME/.ssh/config"
MARKER="# tmux-remote-helper"
# Fallback outside ~/.ssh — shared with sft. We never chmod/chown ~/.ssh
# to "fix" perms; if ~/.ssh/config is not writable we store hosts here.
FALLBACK_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/scpt/hosts"

# ── colors & logging (respects NO_COLOR, non-tty) ─────────────────────
_setup_colors() {
  if [ -n "${NO_COLOR:-}" ]; then
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""; C_BLUE=""
    return
  fi
  if [ -t 1 ] || [ -t 2 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""; C_BLUE=""
  fi
}
_setup_colors
log_info()  { echo -e "${C_CYAN}→${C_RESET} $*" ; }
log_ok()    { echo -e "${C_GREEN}✓${C_RESET} $*" ; }
log_warn()  { echo -e "${C_YELLOW}⚠${C_RESET} $*" >&2 ; }
log_error() { echo -e "${C_RED}✗${C_RESET} $*" >&2 ; }
log_dim()   { echo -e "${C_DIM}$*${C_RESET}" ; }

# Warn (once, at the human-facing entry points) if the terminal doesn't look
# like it supports 256-color or truecolor — the menu/statusline/pane-border
# styling all assume at least 256-color, and will render as garbled escape
# sequences or wrong colors otherwise. Not fatal, just a heads-up.
check_color_support() {
  [ -n "${NO_COLOR:-}" ] && return 0
  [ -t 1 ] || [ -t 2 ] || return 0
  case "${COLORTERM:-}" in
    truecolor|24bit) return 0 ;;
  esac
  local colors colors_str="unknown"
  colors="$(tput colors 2>/dev/null || echo "")"
  if [ -n "$colors" ] && [ "$colors" -ge 256 ] 2>/dev/null; then
    return 0
  fi
  [ -n "$colors" ] && colors_str="$colors"
  log_warn "Terminal may not support 256-color/truecolor (TERM=${TERM:-unset}, tput colors=$colors_str) — the menu and statusline colors may look wrong."
  log_dim "  Try setting TERM=xterm-256color, or use a terminal/SSH client with truecolor support."
}

require_ssh() {
  if ! command -v ssh >/dev/null 2>&1; then
    log_error "ssh is not installed on this machine."
    log_dim "  Install: ${C_BOLD}sudo apt update && sudo apt install -y openssh-client${C_RESET}"
    log_dim "  (Fedora: sudo dnf install openssh-clients | macOS: brew install openssh | Arch: sudo pacman -S openssh)"
    log_dim "  Then re-run: bash \"$SCRIPT\" --add"
    return 1
  fi
}
require_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    log_error "tmux is not installed on this machine."
    log_dim "  Install: ${C_BOLD}sudo apt update && sudo apt install -y tmux${C_RESET}"
    log_dim "  (Fedora: sudo dnf install tmux | macOS: brew install tmux | Arch: sudo pacman -S tmux)"
    log_dim "  Then re-run: bash \"$SCRIPT\" --bind"
    return 1
  fi
}

# ── ensure ~/.ssh/config is usable (permission-preserving, never clobbers) ─
ensure_ssh_config() {
  local ssh_dir="$HOME/.ssh"
  if [ ! -d "$ssh_dir" ]; then
    if ! mkdir -p "$ssh_dir" 2>/dev/null; then
      log_warn "cannot create $ssh_dir (permission denied)."
      return 1
    fi
  fi
  # Only touch permissions if we own the dir/file — never chown/chmod root-owned paths
  if [ -O "$ssh_dir" ] 2>/dev/null; then
    local cur
    cur="$(stat -c %a "$ssh_dir" 2>/dev/null || echo "")"
    # only tighten if clearly too open; don't fight intentional 755 etc. silently
    if [ "$cur" != "700" ] && [ "$cur" != "755" ]; then
      chmod 700 "$ssh_dir" 2>/dev/null || true
    fi
  fi
  if [ ! -e "$SSH_CONFIG" ]; then
    if ! touch "$SSH_CONFIG" 2>/dev/null; then
      log_warn "cannot create $SSH_CONFIG (permission denied)."
      log_dim "  Hint: ls -l \"$SSH_CONFIG\" ; sudo chown \"\$USER:\$USER\" \"$SSH_CONFIG\" if owned by root."
      return 1
    fi
  fi
  if [ -e "$SSH_CONFIG" ] && [ -O "$SSH_CONFIG" ] 2>/dev/null; then
    local fcur
    fcur="$(stat -c %a "$SSH_CONFIG" 2>/dev/null || echo "")"
    if [ "$fcur" != "600" ]; then
      chmod 600 "$SSH_CONFIG" 2>/dev/null || true
    fi
  fi
  if [ -e "$SSH_CONFIG" ] && [ ! -r "$SSH_CONFIG" ]; then
    log_warn "$SSH_CONFIG is not readable (owner: $(stat -c %U "$SSH_CONFIG" 2>/dev/null))."
    log_dim "  Fix: sudo chown \$USER:\$USER \"$SSH_CONFIG\" && chmod 600 \"$SSH_CONFIG\""
    return 1
  fi
  if [ -e "$SSH_CONFIG" ] && [ ! -w "$SSH_CONFIG" ]; then
    log_warn "$SSH_CONFIG is not writable."
    return 1
  fi
  return 0
}
ensure_ssh_config >/dev/null 2>&1 || true

# ── ensure tmux basics + statusline (always on) ─────────────────────
ensure_tmux_conf_file() {
  local tmux_conf="$HOME/.tmux.conf"
  local tmp
  # Create file if missing (644, don't break perms)
  if [ ! -e "$tmux_conf" ]; then
    touch "$tmux_conf" 2>/dev/null && chmod 644 "$tmux_conf" 2>/dev/null || true
  fi
  # Only append if not already present (idempotent, respects existing user config)
  for line in \
    'set -g mouse on' \
    'set -g focus-events on' \
    'set -g set-clipboard on' \
    'set -g default-terminal "tmux-256color"' \
    'set -as terminal-features ",gnome*:RGB"' \
    'set -g set-titles on' \
    'set -g set-titles-string "#{session_name}: #{pane_current_command}#{?@scpt_remote, (#{@scpt_remote}),}"'; do
    if [ -f "$tmux_conf" ] && ! grep -qF "$line" "$tmux_conf" 2>/dev/null; then
      # Ensure we can write without breaking perms
      if [ -w "$tmux_conf" ] || [ ! -e "$tmux_conf" ]; then
        printf "%s\n" "$line" >>"$tmux_conf" 2>/dev/null || true
      fi
    fi
  done
}

ensure_tmux_basics() {
  # Live settings for current tmux server (no file edit needed for immediate effect)
  # Use 2>/dev/null || true for older tmux versions that lack some options
  tmux set-option -g mouse on 2>/dev/null || true
  tmux set-option -g focus-events on 2>/dev/null || true
  tmux set-option -g set-clipboard on 2>/dev/null || true
  tmux set-option -g default-terminal "tmux-256color" 2>/dev/null || true
  if ! tmux show-options -g terminal-features 2>/dev/null | grep -q "gnome\*:RGB"; then
    tmux set-option -as terminal-features ",gnome*:RGB" 2>/dev/null || true
  fi
  # Terminal title tracks the ACTIVE pane (updates on every pane/window
  # switch, since these format variables are current-pane-relative) —
  # otherwise it's stuck on whatever the terminal emulator set it to when
  # scpt.sh was first launched (e.g. "bash scpt.sh").
  tmux set-option -g set-titles on 2>/dev/null || true
  tmux set-option -g set-titles-string "#{session_name}: #{pane_current_command}#{?@scpt_remote, (#{@scpt_remote}),}" 2>/dev/null || true
  # Minimal statusline: session name, clock, and a cyan dot next to any
  # window running an scpt-managed remote session so it's obvious which
  # windows are local vs. remote.
  tmux set-option -g status on 2>/dev/null || true
  tmux set-option -g status-interval 5 2>/dev/null || true
  tmux set-option -g status-position bottom 2>/dev/null || true
  tmux set-option -g status-justify left 2>/dev/null || true
  tmux set-option -g status-style "bg=colour235,fg=colour245" 2>/dev/null || true
  tmux set-option -g status-left-length 20 2>/dev/null || true
  tmux set-option -g status-right-length 20 2>/dev/null || true
  tmux set-option -g status-left "#[fg=colour39,bold] #S " 2>/dev/null || true
  tmux set-option -g status-right "#[fg=colour245] %H:%M " 2>/dev/null || true
  tmux set-option -g window-status-format "#[fg=colour245] #I:#W#{?@scpt_remote,#[fg=colour39] ●,} " 2>/dev/null || true
  tmux set-option -g window-status-current-format "#[fg=colour235,bg=colour245,bold] #I:#W#{?@scpt_remote,#[fg=colour39] ●,} #[fg=colour245,bg=colour235]" 2>/dev/null || true
  tmux set-option -g window-status-separator "" 2>/dev/null || true
  tmux set-option -g pane-border-style "fg=colour240" 2>/dev/null || true
  tmux set-option -g pane-active-border-style "fg=colour39" 2>/dev/null || true
  tmux set-option -g pane-border-lines single 2>/dev/null || true
  # Ensure conf file for future servers
  ensure_tmux_conf_file 2>/dev/null || true
}
# Note: ensure_tmux_basics (statusbar/colors) is intentionally NOT auto-applied
# here. It's only called when scpt creates a brand-new tmux session (i.e. run
# outside of tmux) — see install_binding(). Running scpt from inside an
# existing tmux session only installs bindings (--bind), leaving your
# statusbar/colors alone.

# ── read managed hosts back out of ~/.ssh/config ─────────────────────
# Hosts may live in either ~/.ssh/config (preferred, writable) or the
# fallback FALLBACK_CONFIG (when ~/.ssh is not writable / readable). We
# never chmod/chown ~/.ssh to make it writable — we just use the fallback.
_list_hosts_from_file() { # $1 = file path
  [ -r "$1" ] || return 0
  awk -v marker="$MARKER" '
    $0 == marker { managed = 1; next }
    /^[Hh]ost[[:space:]]+/ {
      if (alias != "" && was_managed) print alias "\t" hn "\t" usr "\t" idf
      alias = $2; hn = ""; usr = ""; idf = ""
      was_managed = managed; managed = 0
      next
    }
    was_managed && /^[[:space:]]*[Hh]ost[Nn]ame[[:space:]]+/ { hn = $2 }
    was_managed && /^[[:space:]]*[Uu]ser[[:space:]]+/        { usr = $2 }
    was_managed && /^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]]+/ { idf = $2 }
    END { if (alias != "" && was_managed) print alias "\t" hn "\t" usr "\t" idf }
  ' "$1" 2>/dev/null || true
}

list_hosts() { # prints alias \t hostname \t user \t identityfile (merged, deduped)
  local primary fallback seen
  primary="$(_list_hosts_from_file "$SSH_CONFIG")"
  fallback="$(_list_hosts_from_file "$FALLBACK_CONFIG")"
  # Print primary first
  [ -n "$primary" ] && printf '%s\n' "$primary"
  if [ -n "$fallback" ]; then
    # For fallback entries, skip any alias already in primary
    local seen_aliases
    seen_aliases="$(printf '%s\n' "$primary" | cut -f1 | tr '\n' '|')"
    while IFS=$'\t' read -r alias hn usr idf; do
      [ -z "$alias" ] && continue
      if printf '%s' "$seen_aliases" | grep -qF "${alias}|"; then
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$alias" "$hn" "$usr" "$idf"
    done <<< "$fallback"
  fi
}

alias_exists() { # alias — checks both primary and fallback
  if [ -r "$SSH_CONFIG" ] && grep -qE "^Host[[:space:]]+$1\$" "$SSH_CONFIG" 2>/dev/null; then return 0; fi
  if [ -r "$FALLBACK_CONFIG" ] && grep -qE "^Host[[:space:]]+$1\$" "$FALLBACK_CONFIG" 2>/dev/null; then return 0; fi
  return 1
}

alias_in_ssh_config() { # alias — only primary ~/.ssh/config
  [ -r "$SSH_CONFIG" ] || return 1
  grep -qE "^Host[[:space:]]+$1\$" "$SSH_CONFIG" 2>/dev/null
}

_ssh_config_writable() { # true if we can append to ~/.ssh/config without changing perms
  if [ -e "$SSH_CONFIG" ]; then
    [ -w "$SSH_CONFIG" ] && return 0 || return 1
  fi
  if [ -d "$HOME/.ssh" ]; then
    [ -w "$HOME/.ssh" ] && return 0 || return 1
  fi
  [ -w "$HOME" ] && return 0 || return 1
}

ensure_fallback_config() {
  local dir
  dir="$(dirname "$FALLBACK_CONFIG")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || true
  fi
  if [ ! -e "$FALLBACK_CONFIG" ]; then
    touch "$FALLBACK_CONFIG" 2>/dev/null || return 1
    chmod 600 "$FALLBACK_CONFIG" 2>/dev/null || true
  fi
  [ -w "$FALLBACK_CONFIG" ] || return 1
  return 0
}

# lookup a host's details from fallback (or primary) — prints hn<TAB>usr<TAB>idf
_lookup_host() { # alias
  local alias="$1" hit
  hit="$(_list_hosts_from_file "$SSH_CONFIG" | awk -F'\t' -v a="$alias" '$1==a{print $2"\t"$3"\t"$4; exit}')"
  [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
  hit="$(_list_hosts_from_file "$FALLBACK_CONFIG" | awk -F'\t' -v a="$alias" '$1==a{print $2"\t"$3"\t"$4; exit}')"
  [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
  return 1
}

append_managed_host() { # alias hostname user identityfile x11(0/1)
  local alias="$1" hn="$2" usr="$3" idf="$4" x11="${5:-0}"
  # Prefer primary ~/.ssh/config if writable — never chmod/chown to force it
  if _ssh_config_writable; then
    if ensure_ssh_config 2>/dev/null && [ -w "$SSH_CONFIG" ]; then
      cp "$SSH_CONFIG" "$SSH_CONFIG.bak" 2>/dev/null || true
      {
        echo ""
        echo "$MARKER"
        echo "Host $alias"
        echo "    HostName $hn"
        echo "    User $usr"
        [ -n "$idf" ] && echo "    IdentityFile $idf"
        if [ "$x11" = "1" ]; then
          echo "    ForwardX11 yes"
          echo "    ForwardX11Trusted yes"
        fi
        echo "    ControlMaster auto"
        echo "    ControlPath ~/.ssh/cm-%r@%h:%p"
        echo "    ControlPersist 10m"
      } >>"$SSH_CONFIG"
      # chmod only the file we just wrote, not the directory if we didn't own it
      chmod 600 "$SSH_CONFIG" 2>/dev/null || true
      alias_in_ssh_config "$alias" && return 0
      log_warn "write to $SSH_CONFIG did not persist — trying fallback"
    fi
  fi
  # Fallback: XDG config path, shared with sft
  if ! ensure_fallback_config; then
    echo "Cannot write to $FALLBACK_CONFIG either — not saving." >&2
    echo "Checked: $SSH_CONFIG (writable: $([ -w "$SSH_CONFIG" ] 2>/dev/null && echo yes || echo no)) and $FALLBACK_CONFIG" >&2
    return 1
  fi
  cp "$FALLBACK_CONFIG" "$FALLBACK_CONFIG.bak" 2>/dev/null || true
  {
    echo ""
    echo "$MARKER"
    echo "Host $alias"
    echo "    HostName $hn"
    echo "    User $usr"
    [ -n "$idf" ] && echo "    IdentityFile $idf"
    if [ "$x11" = "1" ]; then
      echo "    ForwardX11 yes"
      echo "    ForwardX11Trusted yes"
    fi
    echo "    ControlMaster auto"
    echo "    ControlPath ~/.ssh/cm-%r@%h:%p"
    echo "    ControlPersist 10m"
  } >>"$FALLBACK_CONFIG"
  chmod 600 "$FALLBACK_CONFIG" 2>/dev/null || true
  log_info "Saved host '$alias' to fallback $FALLBACK_CONFIG ( ~/.ssh/config not writable )"
}

# ── active ssh ControlMaster sockets (existing connections) ───────
list_active_ssh() { # prints userhost \t hn \t usr \t socket
  local sock
  for sock in "$HOME"/.ssh/cm-*; do
    [ -S "$sock" ] 2>/dev/null || [ -e "$sock" ] || continue
    local base="${sock##*/}"
    base="${base#cm-}"
    local userhost="${base%:*}"
    [ "$userhost" = "$base" ] && continue
    local usr="${userhost%%@*}"
    local hn="${userhost#*@}"
    [ -z "$usr" ] || [ -z "$hn" ] && continue
    # Optional: only show if master is alive (fast check)
    # ssh -O check -S "$sock" dummy 2>/dev/null || continue
    printf "%s\t%s\t%s\t%s\n" "$userhost" "$hn" "$usr" "$sock"
  done 2>/dev/null
}

# ── active docker containers ──────────────────────────────────────────
# Discovery is context-aware: with no target it inspects this machine;
# given an ssh target it inspects that machine instead (reusing the
# ControlMaster connection, so no extra auth prompt) — a pc you're
# currently ssh'd into is treated exactly like the local machine.
list_docker_containers() { # [ssh-target] — prints name \t image \t id
  local target="${1:-}"
  if [ -z "$target" ]; then
    command -v docker >/dev/null 2>&1 || return 0
    docker ps --format '{{.Names}}\t{{.Image}}\t{{.ID}}' 2>/dev/null || true
  else
    command -v ssh >/dev/null 2>&1 || return 0
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$target" \
      "docker ps --format '{{.Names}}\t{{.Image}}\t{{.ID}}'" 2>/dev/null || true
  fi
}

# ── scpt -l : list everything (tmux sessions, docker, remotes) ───────
list_all() {
  require_tmux 2>/dev/null || true
  echo -e "${C_BOLD}══ scpt -l : all available targets ══${C_RESET}"
  echo ""
  # tmux sessions
  echo -e "${C_BOLD}tmux sessions:${C_RESET}"
  if command -v tmux >/dev/null 2>&1 && tmux ls 2>/dev/null; then
    tmux ls 2>/dev/null | sed 's/^/  /'
  else
    echo -e "  ${C_DIM}(no tmux server / no sessions)${C_RESET}"
  fi
  echo ""
  # tmux panes (live, with context)
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    echo -e "${C_BOLD}tmux panes (live):${C_RESET}"
    tmux list-panes -a -F "  #{session_name}:#{window_index}.#{pane_index} #{pane_id} #{pane_current_path} #{?@scpt_remote,#[fg=cyan]#{@scpt_remote} (#{@scpt_remote_type}) ,local}" 2>/dev/null | sed "s/^/  /" || echo -e "  ${C_DIM}(none)${C_RESET}"
    echo ""
  fi
  # docker
  echo -e "${C_BOLD}docker containers (local):${C_RESET}"
  if command -v docker >/dev/null 2>&1; then
    local dc
    dc="$(docker ps --format '{{.Names}} ({{.Image}}) {{.ID}}' 2>/dev/null || true)"
    if [ -n "$dc" ]; then echo "$dc" | sed 's/^/  /'; else echo -e "  ${C_DIM}(none)${C_RESET}"; fi
  else
    echo -e "  ${C_DIM}(docker not installed)${C_RESET}"
  fi
  # remote docker if in ssh pane
  local rtarget
  rtarget="$(current_ssh_target 2>/dev/null || true)"
  if [ -n "$rtarget" ]; then
    echo -e "${C_BOLD}docker containers on ${rtarget}:${C_RESET}"
    local rdc
    rdc="$(list_docker_containers "$rtarget" 2>/dev/null || true)"
    if [ -n "$rdc" ]; then echo "$rdc" | sed 's/^/  /'; else echo -e "  ${C_DIM}(none)${C_RESET}"; fi
  fi
  echo ""
  # saved remotes
  echo -e "${C_BOLD}saved remotes (aliases):${C_RESET}"
  local hosts
  hosts="$(list_hosts 2>/dev/null || true)"
  if [ -n "$hosts" ]; then
    echo "$hosts" | while IFS=$'\t' read -r alias hn usr idf; do
      [ -z "$alias" ] && continue
      local tag="agent/key"
      [ -n "$idf" ] && tag="$(basename "$idf")"
      echo -e "  ${C_CYAN}$alias${C_RESET} → $usr@$hn [$tag]"
    done
  else
    echo -e "  ${C_DIM}(none)${C_RESET}"
  fi
  echo ""
  echo -e "${C_BOLD}active connections (ControlMaster):${C_RESET}"
  local act
  act="$(list_active_ssh 2>/dev/null || true)"
  if [ -n "$act" ]; then
    echo "$act" | while IFS=$'\t' read -r userhost hn usr sock; do
      echo -e "  ${C_GREEN}●${C_RESET} $userhost → $usr@$hn ($sock)"
    done
  else
    echo -e "  ${C_DIM}(none)${C_RESET}"
  fi
}

# ── file-transfer (prefix+T) — always targets the CURRENT pane ─────
# No destination picker: the destination is wherever THIS pane is already
# connected (local, the ssh alias/ephemeral host it's attached to, or the
# docker container it's exec'd into) — read straight off @scpt_remote*.
# Runs sft as a full-pane popup overlaying just this pane; the pane's real
# foreground process (shell/ssh/docker exec) keeps running underneath,
# untouched, and no other pane in the session is affected.
transfer_here() {
  require_tmux || { exec "${SHELL:-bash}"; return 1; }
  if [ -z "${TMUX:-}" ]; then
    log_error "Not inside tmux — cannot show transfer UI."
    return 1
  fi
  local pane
  pane="$(tmux display -p "#{pane_id}" 2>/dev/null || echo "")"
  [ -z "$pane" ] && { log_error "Could not resolve current pane."; return 1; }

  # Resolve sft location (installed bin, else dev fallback to sft.py) — kept
  # as an array since the dev fallback is two words ("python3" + path).
  local sft_bin=()
  if [ -x "$HOME/.local/bin/sft" ]; then sft_bin=("$HOME/.local/bin/sft")
  elif command -v sft >/dev/null 2>&1; then sft_bin=("$(command -v sft)")
  else
    local c found=""
    for c in "$(dirname "$SCRIPT")/sft/sft.py" "./sft/sft.py"; do
      [ -f "$c" ] && { found="$c"; break; }
    done
    if [ -n "$found" ]; then sft_bin=(python3 "$found"); else sft_bin=(sft); fi
  fi

  local qcmd
  qcmd="$(printf '%q ' "${sft_bin[@]}" --from-pane "$pane" --to-pane "$pane")"

  # Size/position the popup to exactly this pane's rectangle (not the whole
  # window) so splits/neighboring panes stay visible and untouched. Resolve
  # these to plain numbers ourselves (rather than handing tmux a raw
  # #{pane_width}-style format string for -w/-h/-x/-y) so a resolution
  # failure is visible here instead of silently falling through.
  local pw ph px py
  pw="$(tmux display -p -t "$pane" '#{pane_width}' 2>/dev/null)"
  ph="$(tmux display -p -t "$pane" '#{pane_height}' 2>/dev/null)"
  px="$(tmux display -p -t "$pane" '#{pane_left}' 2>/dev/null)"
  py="$(tmux display -p -t "$pane" '#{pane_top}' 2>/dev/null)"

  # Probe popup support with a trivial, instant command FIRST, and decide
  # the new-window fallback on THAT result — not on the real sft
  # invocation's own exit code. tmux's docs don't guarantee display-popup
  # (with -E) returns 0 regardless of the inner command's exit status, so
  # checking the real run's exit code risked treating "sft quit non-zero"
  # (e.g. Ctrl-C) as "popups don't work" and popping an extra new window
  # open every time.
  local probe_err probe_rc=0
  if [ -n "$pw" ] && [ -n "$ph" ] && [ -n "$px" ] && [ -n "$py" ]; then
    probe_err="$(tmux display-popup -E -t "$pane" -w 1 -h 1 true 2>&1)" || probe_rc=$?
  else
    probe_err="could not resolve pane geometry (pw=$pw ph=$ph px=$px py=$py)"
    probe_rc=1
  fi

  if [ "$probe_rc" = 0 ]; then
    # Full-pane popup, closes itself when sft exits (-E).
    tmux display-popup -E -t "$pane" -w "$pw" -h "$ph" -x "$px" -y "$py" "$qcmd" 2>/dev/null
  else
    log_warn "display-popup unavailable (tmux too old, or no attached client), opening transfer in a new window instead: ${probe_err:-no error output}"
    tmux new-window "bash -c '$qcmd; echo; echo \"[sft] done — Enter to close\"; read -r _; exec \${SHELL:-bash}'" 2>/dev/null || exec "${sft_bin[@]}" --from-pane "$pane" --to-pane "$pane"
  fi
}

# ── the tmux menu (called via prefix+c) ─────────────────────────────
build_menu() {
  check_color_support
  require_tmux || { exec "${SHELL:-bash}"; return 1; }
  if [ -z "${TMUX:-}" ]; then
    log_error "Not inside tmux — cannot show menu. Launching tmux..."
    install_binding --yes
    return
  fi
  # Clean, colorized menu — uses tmux #[...] styles, not shell colors.
  # Every section below is gated on actually having content to show — a
  # section header/divider is only appended once the first real item for
  # it is found, so empty sections never render.
  local hosts_tmp
  hosts_tmp="$(list_hosts)"
  local count=0
  [ -n "$hosts_tmp" ] && count="$(echo "$hosts_tmp" | grep -c .)"
  local title="#[align=centre,fg=cyan,bold] ✦  New Window  #[fg=colour245,dim]— $THIS_HOST "
  if [ "$count" -gt 0 ]; then
    title="$title #[fg=colour245]($count remote$( [ "$count" -eq 1 ] || echo "s"))"
  fi
  local args=(-T "$title" -x C -y C)
  # Local machine
  args+=("#[fg=green]󰣀  This machine #[fg=colour245]($THIS_HOST)" l "new-window")
  local i=1
  if [ -n "$hosts_tmp" ]; then
    while IFS=$'\t' read -r alias hn _usr idf; do
      [ -z "$alias" ] && continue
      [ "$i" -gt 7 ] && break # keep menu keys single-digit
      local tag="agent/key"
      [ -n "$idf" ] && tag="$(basename "$idf")"
      # icon + alias → host dim tag
      local label="#[fg=colour39]󰒋 #[fg=default]$alias #[fg=colour245]→ $hn #[fg=colour240,dim][$tag]"
      args+=("$label" "$i" "new-window \"bash '$SCRIPT' --connect '$alias'\"")
      i=$((i + 1))
    done <<< "$hosts_tmp"
  fi
  # Active ControlMaster connections — show directly so you don't retype
  local active_added=0
  local active_tmp
  active_tmp="$(list_active_ssh)"
  if [ -n "$active_tmp" ]; then
    # Build set of already listed hostnames to avoid duplicates
    local listed_hns
    listed_hns="$(echo "$hosts_tmp" | cut -f2 | tr '\n' '|')"
    local first_active=1
    while IFS=$'\t' read -r userhost hn usr sock; do
      [ -z "$userhost" ] && continue
      # skip if hn already in managed list
      if echo "$listed_hns" | grep -qF "$hn|"; then
        continue
      fi
      [ "$i" -gt 7 ] && break
      if [ "$first_active" -eq 1 ]; then
        args+=("#[fg=colour245,dim]─ active ssh (ControlMaster) — no retype ─" "" "")
        first_active=0
      fi
      local alabel="#[fg=colour141]↻ #[fg=default]$userhost #[fg=colour245,dim](active, reuse)"
      # Use ephemeral connect so ControlMaster is reused, no Host needed
      args+=("$alabel" "$i" "new-window \"bash '$SCRIPT' --connect-ephemeral '$hn' '$usr'\"")
      i=$((i + 1))
      active_added=1
    done <<< "$active_tmp"
  fi
  # Running docker containers — attach via docker exec. Context-aware: if
  # this pane is actively ssh'd into a remote, we list/attach docker on
  # that remote instead of the local machine (treated just like local).
  local docker_ctx docker_ctx_label
  docker_ctx="$(current_ssh_target)"
  docker_ctx_label="$THIS_HOST"
  [ -n "$docker_ctx" ] && docker_ctx_label="$docker_ctx"
  local docker_tmp
  docker_tmp="$(list_docker_containers "$docker_ctx")"
  if [ -n "$docker_tmp" ]; then
    local first_docker=1
    while IFS=$'\t' read -r cname cimage cid; do
      [ -z "$cname" ] && continue
      [ "$i" -gt 9 ] && break # keep menu keys single-digit
      if [ "$first_docker" -eq 1 ]; then
        args+=("#[fg=colour245,dim]─ docker containers on $docker_ctx_label ─" "" "")
        first_docker=0
      fi
      local dlabel="#[fg=blue]󰡨 #[fg=default]$cname #[fg=colour245,dim]($cimage)"
      args+=("$dlabel" "$i" "new-window \"bash '$SCRIPT' --connect-docker '$cname' '$docker_ctx'\"")
      i=$((i + 1))
    done <<< "$docker_tmp"
  fi
  # Actions
  args+=("#[fg=colour141]󰐕  Add new remote #[fg=colour245]— user@host" a "new-window \"bash '$SCRIPT' --add\"")
  if command -v nmap >/dev/null 2>&1; then
    args+=("#[fg=magenta]󰤨  Scan network #[fg=colour245](nmap)" n "new-window \"bash '$SCRIPT' --scan\"")
  fi
  # Footer hint when there are no saved remotes at all (unselectable entry)
  if [ "$count" -eq 0 ]; then
    args+=("#[fg=colour245,dim]No remotes yet — add one above" "" "")
  fi
  tmux display-menu "${args[@]}"
}

uninstall_binding() {
  require_tmux || return 1
  if tmux list-keys -T prefix 2>/dev/null | grep -q "run-shell.*--menu\|run-shell.*--smart"; then
    tmux unbind-key -T prefix c 2>/dev/null || true
    tmux bind-key -T prefix c new-window 2>/dev/null || true
    log_ok "Uninstalled: ${C_BOLD}prefix+c${C_RESET} restored to default ${C_CYAN}new-window${C_RESET}."
  else
    # still ensure default exists
    tmux bind-key -T prefix c new-window 2>/dev/null || true
    log_info "prefix+c was already at default (new-window)."
  fi
  uninstall_smart_splits
}

install_binding() {
  check_color_support
  require_tmux || return 1
  local force="${1:-}" # --yes to skip prompt, --no to skip binding current server
  if [ -z "${TMUX:-}" ]; then
    if ! command -v tmux >/dev/null 2>&1; then
      log_error "tmux is not installed. Install tmux (e.g. 'sudo apt install tmux') and try again."
      exit 1
    fi
    log_info "Not inside tmux — launching tmux session 'main'..."
    # Ensure a tmux server / session exists (works from outside tmux)
    if ! tmux has-session -t main 2>/dev/null; then
      tmux new-session -d -s main 2>/dev/null || tmux new-session -d 2>/dev/null || true
    fi
    # New session/server we spun up ourselves — apply statusbar/colors here only.
    ensure_tmux_basics >/dev/null 2>&1 || true
    # Outside tmux we always bind for the new server (no prompt needed)
    tmux bind-key -T prefix c run-shell "bash '$SCRIPT' --smart-new-window"
    tmux bind-key -T prefix C run-shell "bash '$SCRIPT' --menu" 2>/dev/null || true
    install_smart_splits
    log_ok "Installed: ${C_BOLD}prefix+c${C_RESET} smart (ssh pane→new ssh window, else menu) ${C_DIM}(this server)${C_RESET}."
    log_dim "  prefix+% / prefix+\" multiplex current ssh pane via ControlMaster, no menu"
    # Attach to tmux, replacing the current process (only if interactive)
    if [ -t 0 ] && [ -t 1 ]; then
      exec tmux attach-session -t main 2>/dev/null || exec tmux attach 2>/dev/null || exit 0
    fi
    exit 0
  fi

  # Inside tmux: check what prefix+c currently does
  local cur
  cur="$(tmux list-keys -T prefix 2>/dev/null | grep -E 'bind-key.*[[:space:]]c([[:space:]]|$)' || true)"

  # Already our binding -> just refresh to smart
  if echo "$cur" | grep -q "run-shell.*--menu\|run-shell.*--smart"; then
    tmux bind-key -T prefix c run-shell "bash '$SCRIPT' --smart-new-window"
    tmux bind-key -T prefix C run-shell "bash '$SCRIPT' --menu" 2>/dev/null || true
    install_smart_splits
    log_ok "Installed: ${C_BOLD}prefix+c${C_RESET} smart (ssh→ssh, else menu) ${C_DIM}(this server)${C_RESET}."
    log_dim "  prefix+% / prefix+\" now multiplex ssh panes via ControlMaster"
    return 0
  fi

  # Decide whether to bind this existing server
  local do_bind="yes"
  if [ "$force" = "--no" ] || [ "$force" = "--no-bind" ]; then
    do_bind="no"
  elif [ "$force" = "--yes" ] || [ "$force" = "--force" ] || [ "$force" = "--bind" ]; then
    do_bind="yes"
  else
    # Interactive prompt — ask whether to bind this existing server
    echo -e "${C_CYAN}Current prefix+c:${C_RESET} ${cur:-${C_DIM}not bound (default new-window)${C_RESET}}"
    local ans=""
    if [ -e /dev/tty ]; then
      read -rp "Replace prefix+c with scpt menu in this tmux server? [Y/n]: " ans </dev/tty 2>/dev/null || read -rp "Replace prefix+c with scpt menu in this tmux server? [Y/n]: " ans || true
    else
      read -rp "Replace prefix+c with scpt menu in this tmux server? [Y/n]: " ans || true
    fi
    if [[ "$ans" =~ ^[Nn]$ ]]; then
      do_bind="no"
    fi
  fi

  if [ "$do_bind" = "no" ]; then
    log_info "Skipped: left prefix+c unchanged in this server."
    echo -e "  ${C_DIM}New servers will auto-bind if you add to ~/.bashrc:${C_RESET}"
    echo -e "  ${C_DIM}  [ -n \"\$TMUX\" ] && bash \"$SCRIPT\" --bind >/dev/null${C_RESET}"
    echo -e "  ${C_DIM}Run '$SCRIPT --bind' to force, '--unbind' to restore.${C_RESET}"
    return 0
  fi

  tmux bind-key -T prefix c run-shell "bash '$SCRIPT' --smart-new-window"
  tmux bind-key -T prefix C run-shell "bash '$SCRIPT' --menu" 2>/dev/null || true
  install_smart_splits
  log_ok "Installed: ${C_BOLD}prefix+c${C_RESET} smart (ssh→ssh, else menu) ${C_DIM}(this server)${C_RESET}."
  log_dim "  prefix+% / prefix+\" multiplex ssh panes (no menu)"
  log_dim "  Tip: '$SCRIPT --unbind' to restore defaults"
}

# ── connecting ────────────────────────────────────────────────────────
offer_passwordless() { # alias
  require_ssh || return 1
  local alias="$1"
  read -rp "$(echo -e "${C_CYAN}This host uses password auth. Set up passwordless SSH now? [y/N]: ${C_RESET}")" ans
  [[ "$ans" =~ ^[Yy]$ ]] || return 1
  local key="$HOME/.ssh/id_ed25519"
  if [ ! -f "$key" ]; then
    log_info "No local SSH key found — generating one ($key)..."
    if ! command -v ssh-keygen >/dev/null 2>&1; then
      log_error "ssh-keygen not found — install openssh-client."
      return 1
    fi
    ssh-keygen -t ed25519 -N "" -f "$key" >/dev/null
  fi
  log_info "Copying your public key to $alias ${C_DIM}(you'll be asked for the password once)${C_RESET}..."
  if ! command -v ssh-copy-id >/dev/null 2>&1; then
    log_error "ssh-copy-id not found — install openssh-client."
    return 1
  fi
  if ssh-copy-id -i "${key}.pub" "$alias"; then
    log_ok "Done — future 'ssh $alias' connects won't need a password."
    return 0
  else
    log_warn "ssh-copy-id failed, continuing with password auth."
    return 1
  fi
}

# Remote command for the tmux-persistence default: turn status off on the
# session BEFORE attaching — chaining `new-session -A \; set-option` instead
# sets it only after the client has already attached, so tmux's default
# (undecorated) status line flashes for a moment on every connect.
# Exits 127 if tmux isn't on the remote, matching the plain-ssh-fallback
# exit-code check callers already do.
#
# $1 = remote session name (see _remote_session_name — one dedicated
# session per local pane, NOT shared/grouped). Session groups were tried
# here so panes to one host would show up as windows of one shared session
# on the remote, but tmux group semantics don't support what we actually
# need: a grouped session with no windows of its own falls back to another
# window still in the group rather than detaching, so killing one pane's
# window (typing `exit`) would silently reassign that pane to a *different*
# pane's window instead of ending the connection — worse than the original
# "exit kills every pane" bug, not better. Fully separate sessions per pane
# is the one model where a pane's window closing reliably ends only that
# pane's own session.
_remote_tmux_cmd() {
  local sess="${1:-main}"
  echo "command -v tmux >/dev/null 2>&1 || exit 127; tmux new-session -d -s '$sess' 2>/dev/null; tmux set-option -t '$sess' status off 2>/dev/null; exec tmux attach-session -t '$sess'"
}

# Petname word lists (Docker-container-name style: adjective-noun) purely
# for readability when you `tmux ls` on the remote — "scpt-brave-otter-3"
# reads a lot better than "scpt-3". The trailing pane id is what actually
# guarantees no two panes collide; the words are just decoration derived
# deterministically (hashed) from that same id, so the same local pane
# always maps back to the same name (needed for reload to reattach right).
_SCPT_ADJ=(quick lazy brave silly happy sneaky bold calm eager fuzzy jolly witty gentle mighty nimble plucky spry zesty chill dizzy)
_SCPT_NOUN=(falcon noodle badger walrus muffin rocket cactus penguin wizard goblin ninja pretzel lantern comet turtle otter beetle biscuit yeti pixel)

# Derive a per-pane remote session name so panes to the same host stay
# independent. Falls back to a shared "main" only when there's no local
# pane id to key off (e.g. connect() invoked outside tmux).
_remote_session_name() {
  local pane="${1:-}"
  if [ -z "$pane" ]; then
    echo "main"
    return
  fi
  local id="${pane#%}"
  local h
  h="$(printf '%s' "$id" | cksum | cut -d' ' -f1)"
  local ai=$(( h % ${#_SCPT_ADJ[@]} ))
  local ni=$(( (h / 97) % ${#_SCPT_NOUN[@]} ))
  echo "scpt-${_SCPT_ADJ[$ai]}-${_SCPT_NOUN[$ni]}-${id}"
}

# Called on an intentional/clean end of a connect*() session (ssh/docker
# exited on its own — e.g. you typed `exit`), as opposed to an unexpected
# drop. Undoes the remain-on-exit tagging connect()/connect_ephemeral()/
# connect_docker() set on the pane, so tmux closes it as it always did
# instead of leaving a dead "Shared connection ... closed" placeholder
# behind — that tagging exists only so a pane survives being killed out
# from under it, so prefix+R has something to reconnect.
_close_pane_normally() {
  tmux set-option -pu remain-on-exit 2>/dev/null || true
  exit 0
}

connect() { # alias (persisted host, looked up from ~/.ssh/config or fallback)
  require_ssh || { log_error "Cannot connect — ssh missing."; exec "${SHELL:-bash}"; return 1; }
  local alias="$1"
  [ -z "$alias" ] && {
    log_error "No target given."
    exec "${SHELL:-bash}"
  }
  # Fallback hosts aren't resolvable via `ssh alias` (alias only in
  # FALLBACK_CONFIG, not ~/.ssh/config). Detect and route via ephemeral
  # so no ~/.ssh/config alias resolution is needed.
  if ! alias_in_ssh_config "$alias"; then
    local _lookup
    _lookup="$(_lookup_host "$alias" 2>/dev/null || true)"
    if [ -n "$_lookup" ]; then
      local _hn _usr _idf _x11
      _hn="$(printf '%s' "$_lookup" | cut -f1)"
      _usr="$(printf '%s' "$_lookup" | cut -f2)"
      _idf="$(printf '%s' "$_lookup" | cut -f3)"
      # Check fallback block for ForwardX11 (best-effort)
      _x11=0
      if [ -r "$FALLBACK_CONFIG" ] && awk -v a="$alias" -v m="$MARKER" '
          $0==m{seen=1; next}
          $1=="Host" && $2==a{in_host=1; next}
          in_host && $1=="ForwardX11" && $2=="yes"{found=1; exit}
          $1=="Host"{in_host=0}
          END{exit !found}
        ' "$FALLBACK_CONFIG" 2>/dev/null; then
        _x11=1
      fi
      log_dim "(host '$alias' from fallback $FALLBACK_CONFIG — connecting via ${_usr}@${_hn})"
      connect_ephemeral "$_hn" "$_usr" "$_idf" "$_x11"
      return
    fi
    # Not in managed store at all — try plain ssh anyway (user may have
    # non-managed Host in ~/.ssh/config); fall through.
  fi
  if [ -n "${TMUX:-}" ]; then
    local _pane="${TMUX_PANE:-}"
    local _reconnect="bash '$SCRIPT' --connect '$alias'"
    if [ -n "$_pane" ]; then
      tmux set-option -p -t "$_pane" @scpt_remote "$alias" 2>/dev/null || tmux set-option -p @scpt_remote "$alias" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_remote_type "alias" 2>/dev/null || tmux set-option -p @scpt_remote_type "alias" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_remote_idf "" 2>/dev/null || tmux set-option -p @scpt_remote_idf "" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_reconnect_cmd "$_reconnect" 2>/dev/null || tmux set-option -p @scpt_reconnect_cmd "$_reconnect" 2>/dev/null || true
      tmux set-option -p -t "$_pane" remain-on-exit on 2>/dev/null || tmux set-option -p remain-on-exit on 2>/dev/null || true
      tmux set-hook -p -t "$_pane" pane-died "run-shell \"bash '$SCRIPT' --pane-dropped-notice\"" 2>/dev/null || tmux set-hook -p pane-died "run-shell \"bash '$SCRIPT' --pane-dropped-notice\"" 2>/dev/null || true
    else
      tmux set-option -p @scpt_remote "$alias" 2>/dev/null || true
      tmux set-option -p @scpt_remote_type "alias" 2>/dev/null || true
      tmux set-option -p @scpt_remote_idf "" 2>/dev/null || true
      tmux set-option -p @scpt_reconnect_cmd "$_reconnect" 2>/dev/null || true
      tmux set-option -p remain-on-exit on 2>/dev/null || true
      tmux set-hook -p pane-died "run-shell \"bash '$SCRIPT' --pane-dropped-notice\"" 2>/dev/null || true
    fi
    if ! tmux list-keys -T prefix 2>/dev/null | grep -q "run-shell.*--smart-split"; then
      install_smart_splits 2>/dev/null || true
    fi
  fi
  # Default: use remote tmux (if installed) for persistence, with its status
  # line forced off so only the local/outer tmux status bar is visible.
  # Set SCPT_REMOTE_TMUX=0 (or "never") to force plain ssh instead.
  if [ "${SCPT_REMOTE_TMUX:-1}" != "0" ] && [ "${SCPT_REMOTE_TMUX:-1}" != "never" ]; then
    local _rsess; _rsess="$(_remote_session_name "${_pane:-}")"
    log_info "Connecting to ${C_BOLD}$alias${C_RESET} ${C_DIM}→ tmux session ($_rsess)${C_RESET}..."
    local rc=0
    ssh -t "$alias" "$(_remote_tmux_cmd "$_rsess")" || rc=$?
    if [ $rc -eq 0 ]; then
      # ssh+tmux session ended — close pane like regular tmux pane (exit)
      _close_pane_normally
    fi
    if [ $rc -eq 127 ]; then
      log_warn "Remote has no tmux — falling back to plain shell"
    else
      log_error "ssh to $alias failed (exit $rc)."
      log_dim "  Try manually: ssh -v $alias"
      echo -e "${C_DIM}Pane will stay open. Press Enter to get a shell...${C_RESET}"
      read -r _ || true
      tmux set-option -pu @scpt_remote 2>/dev/null || true
      tmux set-option -pu @scpt_remote_type 2>/dev/null || true
      tmux set-option -pu @scpt_remote_idf 2>/dev/null || true
      exec "${SHELL:-bash}"
    fi
  fi
  log_info "Connecting to ${C_BOLD}$alias${C_RESET}..."
  ssh -t "$alias"
  local rc=$?
  if [ $rc -ne 0 ]; then
    log_error "ssh to $alias failed (exit $rc)."
    log_dim "  Try: ssh -v $alias  (check password/network)"
    echo -e "${C_DIM}Pane will stay open. Press Enter for shell...${C_RESET}"
    read -r _ || true
    tmux set-option -pu @scpt_remote 2>/dev/null || true
    tmux set-option -pu @scpt_remote_type 2>/dev/null || true
    tmux set-option -pu @scpt_remote_idf 2>/dev/null || true
    exec "${SHELL:-bash}"
  fi
  _close_pane_normally
}

connect_ephemeral() { # hostname user identity x11(0/1) — not saved anywhere
  local hn="$1" usr="$2" idf="$3" x11="${4:-0}"
  local opts=(-t
    -o "ControlMaster=auto"
    -o "ControlPath=$HOME/.ssh/cm-%r@%h:%p"
    -o "ControlPersist=10m")
  [ -n "$idf" ] && opts+=(-i "$idf")
  [ "$x11" = "1" ] && opts+=(-X)
  # Mark this pane as an scpt ssh pane so smart splits can multiplex without menu
  if [ -n "${TMUX:-}" ]; then
    local _pane="${TMUX_PANE:-}"
    local _reconnect="bash '$SCRIPT' --connect-ephemeral '$hn' '$usr' '$idf' '$x11'"
    if [ -n "$_pane" ]; then
      tmux set-option -p -t "$_pane" @scpt_remote "${usr}@${hn}" 2>/dev/null || tmux set-option -p @scpt_remote "${usr}@${hn}" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_remote_type "ephemeral" 2>/dev/null || tmux set-option -p @scpt_remote_type "ephemeral" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_remote_idf "${idf:-}" 2>/dev/null || tmux set-option -p @scpt_remote_idf "${idf:-}" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_ssh 1 2>/dev/null || tmux set-option -p @scpt_ssh 1 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_reconnect_cmd "$_reconnect" 2>/dev/null || tmux set-option -p @scpt_reconnect_cmd "$_reconnect" 2>/dev/null || true
      tmux set-option -p -t "$_pane" remain-on-exit on 2>/dev/null || tmux set-option -p remain-on-exit on 2>/dev/null || true
      tmux set-hook -p -t "$_pane" pane-died "run-shell \"bash '$SCRIPT' --pane-dropped-notice\"" 2>/dev/null || tmux set-hook -p pane-died "run-shell \"bash '$SCRIPT' --pane-dropped-notice\"" 2>/dev/null || true
    else
      tmux set-option -p @scpt_remote "${usr}@${hn}" 2>/dev/null || true
      tmux set-option -p @scpt_remote_type "ephemeral" 2>/dev/null || true
      tmux set-option -p @scpt_remote_idf "${idf:-}" 2>/dev/null || true
      tmux set-option -p @scpt_ssh 1 2>/dev/null || true
      tmux set-option -p @scpt_reconnect_cmd "$_reconnect" 2>/dev/null || true
      tmux set-option -p remain-on-exit on 2>/dev/null || true
      tmux set-hook -p pane-died "run-shell \"bash '$SCRIPT' --pane-dropped-notice\"" 2>/dev/null || true
    fi
    if ! tmux list-keys -T prefix 2>/dev/null | grep -q "run-shell.*--smart-split"; then
      install_smart_splits 2>/dev/null || true
    fi
  fi
  # Default: use remote tmux (if installed) for persistence, with its status
  # line forced off. Set SCPT_REMOTE_TMUX=0 (or "never") to force plain ssh.
  if [ "${SCPT_REMOTE_TMUX:-1}" != "0" ] && [ "${SCPT_REMOTE_TMUX:-1}" != "never" ]; then
    local _rsess; _rsess="$(_remote_session_name "${_pane:-}")"
    log_info "Connecting to ${C_BOLD}${usr}@${hn}${C_RESET} ${C_DIM}(not saved → tmux session $_rsess)${C_RESET}..."
    local rc=0
    ssh "${opts[@]}" "${usr}@${hn}" "$(_remote_tmux_cmd "$_rsess")" || rc=$?
    if [ $rc -eq 0 ]; then
      _close_pane_normally
    fi
    if [ $rc -ne 127 ]; then
      log_error "ssh to ${usr}@${hn} failed (exit $rc)."
      echo -e "${C_DIM}Pane will stay open. Press Enter for shell...${C_RESET}"
      read -r _ || true
      tmux set-option -pu @scpt_remote 2>/dev/null || true
      tmux set-option -pu @scpt_remote_type 2>/dev/null || true
      tmux set-option -pu @scpt_remote_idf 2>/dev/null || true
      exec "${SHELL:-bash}"
    fi
    log_warn "Remote has no tmux — falling back to plain shell"
  fi
  log_info "Connecting to ${C_BOLD}${usr}@${hn}${C_RESET} ${C_DIM}(not saved)${C_RESET}..."
  ssh "${opts[@]}" "${usr}@${hn}"
  local rc=$?
  if [ $rc -ne 0 ]; then
    log_error "ssh to ${usr}@${hn} failed (exit $rc)."
    log_dim "  Try: ssh -v ${usr}@${hn}  (password: check caps/typo)"
    echo -e "${C_DIM}Pane will stay open. Press Enter for shell...${C_RESET}"
    read -r _ || true
    tmux set-option -pu @scpt_remote 2>/dev/null || true
    tmux set-option -pu @scpt_remote_type 2>/dev/null || true
    tmux set-option -pu @scpt_remote_idf 2>/dev/null || true
    exec "${SHELL:-bash}"
  fi
  _close_pane_normally
}

connect_docker() { # container name, [ssh-target — host it's running on; empty = this machine]
  local cname="$1" rhost="${2:-}"
  [ -z "$cname" ] && {
    log_error "No container given."
    exec "${SHELL:-bash}"
  }
  if [ -z "$rhost" ] && ! command -v docker >/dev/null 2>&1; then
    log_error "docker is not installed on this machine."
    exec "${SHELL:-bash}"
  fi
  if [ -n "$rhost" ] && ! command -v ssh >/dev/null 2>&1; then
    log_error "ssh is not installed — cannot reach docker on $rhost."
    exec "${SHELL:-bash}"
  fi
  if [ -n "${TMUX:-}" ]; then
    local _pane="${TMUX_PANE:-}"
    local _reconnect="bash '$SCRIPT' --connect-docker '$cname' '$rhost'"
    if [ -n "$_pane" ]; then
      tmux set-option -p -t "$_pane" @scpt_remote "$cname" 2>/dev/null || tmux set-option -p @scpt_remote "$cname" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_remote_type "docker" 2>/dev/null || tmux set-option -p @scpt_remote_type "docker" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_remote_idf "" 2>/dev/null || tmux set-option -p @scpt_remote_idf "" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_docker_host "$rhost" 2>/dev/null || tmux set-option -p @scpt_docker_host "$rhost" 2>/dev/null || true
      tmux set-option -p -t "$_pane" @scpt_reconnect_cmd "$_reconnect" 2>/dev/null || tmux set-option -p @scpt_reconnect_cmd "$_reconnect" 2>/dev/null || true
      tmux set-option -p -t "$_pane" remain-on-exit on 2>/dev/null || tmux set-option -p remain-on-exit on 2>/dev/null || true
      tmux set-hook -p -t "$_pane" pane-died "run-shell \"bash '$SCRIPT' --pane-dropped-notice\"" 2>/dev/null || tmux set-hook -p pane-died "run-shell \"bash '$SCRIPT' --pane-dropped-notice\"" 2>/dev/null || true
    else
      tmux set-option -p @scpt_remote "$cname" 2>/dev/null || true
      tmux set-option -p @scpt_remote_type "docker" 2>/dev/null || true
      tmux set-option -p @scpt_remote_idf "" 2>/dev/null || true
      tmux set-option -p @scpt_docker_host "$rhost" 2>/dev/null || true
      tmux set-option -p @scpt_reconnect_cmd "$_reconnect" 2>/dev/null || true
      tmux set-option -p remain-on-exit on 2>/dev/null || true
      tmux set-hook -p pane-died "run-shell \"bash '$SCRIPT' --pane-dropped-notice\"" 2>/dev/null || true
    fi
    if ! tmux list-keys -T prefix 2>/dev/null | grep -q "run-shell.*--smart-split"; then
      install_smart_splits 2>/dev/null || true
    fi
  fi
  local rc=0
  if [ -n "$rhost" ]; then
    log_info "Attaching to container ${C_BOLD}$cname${C_RESET} ${C_DIM}on $rhost${C_RESET}..."
    # Fallback to sh lives in the remote command itself — one ssh round trip.
    ssh -t "$rhost" "docker exec -it '$cname' bash 2>/dev/null || docker exec -it '$cname' sh"
    rc=$?
  else
    log_info "Attaching to container ${C_BOLD}$cname${C_RESET}..."
    docker exec -it "$cname" bash 2>/dev/null
    rc=$?
    # 126/127: bash missing/not executable in the image — retry with sh.
    # Any other nonzero just means the session inside bash exited that way.
    if [ $rc -eq 126 ] || [ $rc -eq 127 ]; then
      docker exec -it "$cname" sh
      rc=$?
    fi
  fi
  if [ $rc -ne 0 ]; then
    log_error "docker exec into $cname failed (exit $rc)."
    [ -n "$rhost" ] && log_dim "  Try: ssh $rhost docker exec -it $cname sh" || log_dim "  Try: docker exec -it $cname sh"
    echo -e "${C_DIM}Pane will stay open. Press Enter for shell...${C_RESET}"
    read -r _ || true
    tmux set-option -pu @scpt_remote 2>/dev/null || true
    tmux set-option -pu @scpt_remote_type 2>/dev/null || true
    tmux set-option -pu @scpt_remote_idf 2>/dev/null || true
    tmux set-option -pu @scpt_docker_host 2>/dev/null || true
    exec "${SHELL:-bash}"
  fi
  _close_pane_normally
}

# ── reload — reconnect the current pane in place after a dropped connection ──
# connect()/connect_ephemeral()/connect_docker() tag every pane they spawn with
# remain-on-exit + @scpt_reconnect_cmd, so a dropped ssh/docker session leaves a
# "dead" pane (instead of closing) that this can respawn in place.
reload_pane() {
  require_tmux || return 1
  local _pane="${TMUX_PANE:-}"
  local cmd remote
  if [ -n "$_pane" ]; then
    cmd="$(tmux show-option -pv -t "$_pane" @scpt_reconnect_cmd 2>/dev/null || true)"
    remote="$(tmux show-option -pv -t "$_pane" @scpt_remote 2>/dev/null || true)"
  else
    cmd="$(tmux show-option -pv @scpt_reconnect_cmd 2>/dev/null || true)"
    remote="$(tmux show-option -pv @scpt_remote 2>/dev/null || true)"
  fi
  if [ -z "$cmd" ]; then
    tmux display-message "scpt: this pane isn't a saved remote/docker connection — nothing to reload" 2>/dev/null || true
    return 0
  fi
  tmux display-message "scpt: reloading $remote…" 2>/dev/null || true
  if [ -n "$_pane" ]; then
    tmux respawn-pane -k -t "$_pane" "$cmd" 2>/dev/null || true
  else
    tmux respawn-pane -k "$cmd" 2>/dev/null || true
  fi
}

# Fired by a per-pane `pane-died` hook installed alongside remain-on-exit —
# just a status-line nudge; reload stays an explicit prefix+R action so a
# genuinely-gone host doesn't get retried in a silent loop.
pane_dropped_notice() {
  require_tmux || return 1
  local _pane="${TMUX_PANE:-}" remote
  if [ -n "$_pane" ]; then
    remote="$(tmux show-option -pv -t "$_pane" @scpt_remote 2>/dev/null || true)"
  else
    remote="$(tmux show-option -pv @scpt_remote 2>/dev/null || true)"
  fi
  [ -n "$remote" ] && tmux display-message "scpt: connection to $remote dropped — prefix+R to reload" 2>/dev/null || true
}

# ── pane multiplexing — local tmux views remote via multiplexed ssh ──
# Each scpt ssh pane is tagged with @scpt_remote so splits/new-windows
# from it can auto-ssh to the same host without going through the menu.
# ControlMaster in ssh config / opts makes extra panes reuse the same TCP connection.
set_pane_remote() { # internal: tag current pane
  local remote="$1" rtype="$2" idf="${3:-}"
  if [ -n "${TMUX:-}" ]; then
    tmux set-option -p @scpt_remote "$remote" 2>/dev/null || true
    tmux set-option -p @scpt_remote_type "$rtype" 2>/dev/null || true
    tmux set-option -p @scpt_remote_idf "$idf" 2>/dev/null || true
  fi
}

is_remote_pane_active() { # $1 = process name to look for (default ssh); true if pane has that descendant
  local proc="${1:-ssh}"
  local remote pane_pid
  remote="$(tmux display -p "#{@scpt_remote}" 2>/dev/null || echo "")"
  [ -n "$remote" ] || return 1
  # Prefer TMUX_PANE if set (inside the pane's own shell), else active pane
  pane_pid="$(tmux display -p -t "${TMUX_PANE:-}" "#{pane_pid}" 2>/dev/null || tmux display -p "#{pane_pid}" 2>/dev/null || echo "")"
  [ -n "$pane_pid" ] || return 1
  # Use pstree if available for deep check
  if command -v pstree >/dev/null 2>&1; then
    pstree -p "$pane_pid" 2>/dev/null | grep -qw "$proc" && return 0
  fi
  # Direct child
  if ps --ppid "$pane_pid" -o comm= 2>/dev/null | grep -qw "$proc"; then return 0; fi
  pgrep -P "$pane_pid" "$proc" >/dev/null 2>&1 && return 0
  # Grandchild (bash -> ssh/docker)
  local child
  for child in $(pgrep -P "$pane_pid" 2>/dev/null); do
    ps -o comm= -p "$child" 2>/dev/null | grep -qw "$proc" && return 0
    pgrep -P "$child" "$proc" >/dev/null 2>&1 && return 0
    # one more level
    local grand
    for grand in $(pgrep -P "$child" 2>/dev/null); do
      ps -o comm= -p "$grand" 2>/dev/null | grep -qw "$proc" && return 0
    done
  done
  return 1
}
is_ssh_pane_active() { is_remote_pane_active ssh; }

# Echoes an ssh-connectable target ("alias" or "user@host") if the current
# pane is actively ssh'd into a remote — empty otherwise. Used to make
# discovery (docker, etc.) context-aware: a pc you're ssh'd into gets
# treated the same as the local machine, just reached via ssh instead of
# running directly.
current_ssh_target() {
  local remote rtype
  remote="$(tmux display -p "#{@scpt_remote}" 2>/dev/null || echo "")"
  rtype="$(tmux display -p "#{@scpt_remote_type}" 2>/dev/null || echo "")"
  [ -n "$remote" ] || return 0
  case "$rtype" in
    alias|ephemeral) is_ssh_pane_active && echo "$remote" ;;
  esac
}

smart_split() { # h or v — called via tmux bind
  require_tmux || return 1
  local dir="${1:-h}"
  local remote rtype ridf dockerhost
  remote="$(tmux display -p "#{@scpt_remote}" 2>/dev/null || echo "")"
  rtype="$(tmux display -p "#{@scpt_remote_type}" 2>/dev/null || echo "")"
  ridf="$(tmux display -p "#{@scpt_remote_idf}" 2>/dev/null || echo "")"
  dockerhost="$(tmux display -p "#{@scpt_docker_host}" 2>/dev/null || echo "")"
  [ "$remote" = "" ] && remote=""
  if [ -n "$remote" ] && [ "$rtype" = "docker" ]; then
    # If the container lives on a remote host we got there over ssh, so the
    # local descendant process is ssh, not docker — check accordingly.
    local docker_active=0
    if [ -n "$dockerhost" ]; then
      is_remote_pane_active ssh && docker_active=1
    else
      is_remote_pane_active docker && docker_active=1
    fi
    if [ "$docker_active" = "1" ]; then
      if [ "$dir" = "h" ]; then
        tmux split-window -h "bash '$SCRIPT' --connect-docker '$remote' '$dockerhost'"
      else
        tmux split-window -v "bash '$SCRIPT' --connect-docker '$remote' '$dockerhost'"
      fi
      return 0
    fi
  fi
  if [ -n "$remote" ] && [ -n "$rtype" ] && is_ssh_pane_active; then
    if [ "$rtype" = "alias" ]; then
      if [ "$dir" = "h" ]; then
        tmux split-window -h "bash '$SCRIPT' --connect '$remote'"
      else
        tmux split-window -v "bash '$SCRIPT' --connect '$remote'"
      fi
    else
      local usr hn
      usr="${remote%%@*}"; hn="${remote#*@}"
      if [ -n "$ridf" ]; then
        if [ "$dir" = "h" ]; then
          tmux split-window -h "bash '$SCRIPT' --connect-ephemeral '$hn' '$usr' '$ridf'"
        else
          tmux split-window -v "bash '$SCRIPT' --connect-ephemeral '$hn' '$usr' '$ridf'"
        fi
      else
        if [ "$dir" = "h" ]; then
          tmux split-window -h "bash '$SCRIPT' --connect-ephemeral '$hn' '$usr'"
        else
          tmux split-window -v "bash '$SCRIPT' --connect-ephemeral '$hn' '$usr'"
        fi
      fi
    fi
    return 0
  fi
  if [ "$dir" = "h" ]; then tmux split-window -h
  else tmux split-window -v
  fi
}

smart_new_window() {
  require_tmux || { build_menu; return 1; }
  local remote rtype ridf dockerhost
  remote="$(tmux display -p "#{@scpt_remote}" 2>/dev/null || echo "")"
  rtype="$(tmux display -p "#{@scpt_remote_type}" 2>/dev/null || echo "")"
  ridf="$(tmux display -p "#{@scpt_remote_idf}" 2>/dev/null || echo "")"
  dockerhost="$(tmux display -p "#{@scpt_docker_host}" 2>/dev/null || echo "")"
  if [ -n "$remote" ] && [ "$rtype" = "docker" ]; then
    local docker_active=0
    if [ -n "$dockerhost" ]; then
      is_remote_pane_active ssh && docker_active=1
    else
      is_remote_pane_active docker && docker_active=1
    fi
    if [ "$docker_active" = "1" ]; then
      tmux new-window "bash '$SCRIPT' --connect-docker '$remote' '$dockerhost'"
      return 0
    fi
  fi
  if [ -n "$remote" ] && [ -n "$rtype" ] && is_ssh_pane_active; then
    if [ "$rtype" = "alias" ]; then
      tmux new-window "bash '$SCRIPT' --connect '$remote'"
    else
      local usr hn; usr="${remote%%@*}"; hn="${remote#*@}"
      if [ -n "$ridf" ]; then
        tmux new-window "bash '$SCRIPT' --connect-ephemeral '$hn' '$usr' '$ridf'"
      else
        tmux new-window "bash '$SCRIPT' --connect-ephemeral '$hn' '$usr'"
      fi
    fi
    return 0
  fi
  build_menu
}

install_smart_splits() {
  require_tmux || return 1
  # Smart splits/new-window that multiplex the current ssh pane via ControlMaster
  # Falls back to normal splits when not in an scpt ssh pane.
  tmux bind-key -T prefix % run-shell "bash '$SCRIPT' --smart-split h" 2>/dev/null || true
  tmux bind-key -T prefix '"' run-shell "bash '$SCRIPT' --smart-split v" 2>/dev/null || true
  # prefix+c smart: in ssh pane → new ssh window, else menu
  tmux bind-key -T prefix c run-shell "bash '$SCRIPT' --smart-new-window" 2>/dev/null || true
  tmux bind-key -T prefix C run-shell "bash '$SCRIPT' --menu" 2>/dev/null || true
  # prefix+T file transfer: full-pane sft targeting THIS pane's own connection (rsync, docker cp exception)
  tmux bind-key -T prefix T run-shell "bash '$SCRIPT' --transfer-here" 2>/dev/null || true
  # prefix+R reload: reconnect the current pane in place if its connection dropped
  tmux bind-key -T prefix R run-shell "bash '$SCRIPT' --reload-pane" 2>/dev/null || true
}

uninstall_smart_splits() {
  require_tmux || return 1
  tmux unbind-key -T prefix % 2>/dev/null || true
  tmux unbind-key -T prefix '"' 2>/dev/null || true
  tmux unbind-key -T prefix T 2>/dev/null || true
  tmux unbind-key -T prefix R 2>/dev/null || true
  tmux bind-key -T prefix % split-window -h 2>/dev/null || true
  tmux bind-key -T prefix '"' split-window -v 2>/dev/null || true
}

# ── adding a host ────────────────────────────────────────────────────
# Probe the remote SSH server for what auth it advertises.
# Sets globals PROBE_METHODS / PROBE_HINT for the next chooser.
probe_ssh_server() {
  require_ssh || { PROBE_HINT="unknown"; return 1; }
  local usr="$1" hn="$2"
  PROBE_METHODS=""
  PROBE_HINT="unknown"
  log_info "Probing ${C_BOLD}$usr@$hn${C_RESET} for SSH auth ${C_DIM}(timeout 5s)${C_RESET}..."
  local v_out none_out
  none_out="$(ssh -v -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=none "$usr@$hn" exit 2>&1 || true)"
  v_out="$(ssh -vv -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$usr@$hn" exit 2>&1 || true)"
  local methods=""
  methods="$(echo "$none_out" | grep -i "Authentications that can continue" | tail -1 | sed -E 's/.*Authentications that can continue: //I' | tr -d '\r')"
  if [ -z "$methods" ]; then
    methods="$(echo "$v_out" | grep -i "Authentications that can continue" | tail -1 | sed -E 's/.*Authentications that can continue: //I' | tr -d '\r')"
  fi
  if echo "$v_out" | grep -qi "Authentication succeeded"; then
    log_ok "Your current key already authenticates ${C_DIM}(publickey succeeded)${C_RESET}."
    PROBE_METHODS="$methods"
    PROBE_HINT="key-ok"
    return 0
  fi
  if [ -n "$methods" ]; then
    echo -e "  ${C_GREEN}→${C_RESET} Server advertises: ${C_BOLD}$methods${C_RESET}"
    PROBE_METHODS="$methods"
    local mlower
    mlower="$(echo "$methods" | tr '[:upper:]' '[:lower:]')"
    if [[ "$mlower" == *"password"* ]] || [[ "$mlower" == *"keyboard-interactive"* ]]; then
      echo -e "    ${C_YELLOW}Hint:${C_RESET} password/keyboard-interactive available."
      PROBE_HINT="password"
    elif [[ "$mlower" == *"publickey"* ]]; then
      echo -e "    ${C_YELLOW}Hint:${C_RESET} publickey only — keyfile (.pem) or ssh-copy-id needed."
      PROBE_HINT="publickey"
    else
      PROBE_HINT="unknown"
    fi
  else
    local err
    err="$(echo "$none_out" | grep -iE 'No route to host|Connection timed out|Could not resolve|Connection refused|Network is unreachable' | head -1)"
    [ -z "$err" ] && err="$(echo "$v_out" | grep -iE 'No route to host|Connection timed out|Could not resolve|Connection refused|Network is unreachable' | head -1)"
    if [ -n "$err" ]; then
      log_warn "Probe note: $err"
      log_dim "  (host may be offline; you can still save it and choose auth manually)"
      PROBE_HINT="unreachable"
    else
      log_dim "  → Could not determine auth methods (server may be offline). You'll choose manually."
      PROBE_HINT="unknown"
    fi
  fi
}

choose_auth_method() { # sets globals: METHOD, IDENTITY — uses PROBE_HINT if set
  echo -e "${C_BOLD}Auth method for this host:${C_RESET}"
  if [ -n "${PROBE_METHODS:-}" ]; then
    echo -e "  ${C_DIM}server says: ${C_BOLD}$PROBE_METHODS${C_RESET}${C_DIM} → hint: $PROBE_HINT${C_RESET}"
  elif [ "${PROBE_HINT:-}" != "unknown" ] && [ -n "${PROBE_HINT:-}" ]; then
    echo -e "  ${C_DIM}hint: $PROBE_HINT${C_RESET}"
  fi
  local ps3="${C_CYAN}Pick auth [1-3]: ${C_RESET}"
  local opts=()
  case "${PROBE_HINT:-}" in
    key-ok) opts=("${C_GREEN}SSH key (agent/default) — recommended${C_RESET}" "Keyfile (e.g. AWS .pem)" "Password");;
    password) opts=("SSH key (agent/default)" "Keyfile (e.g. AWS .pem)" "${C_YELLOW}Password — suggested by server${C_RESET}");;
    publickey) opts=("SSH key (agent/default)" "${C_YELLOW}Keyfile (e.g. AWS .pem) — suggested${C_RESET}" "Password");;
    *) opts=("SSH key (agent/default)" "Keyfile (e.g. AWS .pem)" "Password");;
  esac
  local choice
  PS3="$ps3"
  select choice in "${opts[@]}"; do
    case "$REPLY" in
    1) METHOD="key"; IDENTITY=""; break ;;
    2)
      METHOD="pem"
      read -rp "Path to keyfile: " IDENTITY
      IDENTITY="${IDENTITY/#\~/$HOME}"
      [ -f "$IDENTITY" ] || log_warn "file not found at $IDENTITY"
      break
      ;;
    3) METHOD="password"; IDENTITY=""; break ;;
    *) echo "Pick 1, 2, or 3." ;;
    esac
  done
}

finalize_add() { # alias hostname user
  local alias="$1" hn="$2" usr="$3"
  if [ -z "${PROBE_HINT:-}" ]; then
    probe_ssh_server "$usr" "$hn"
  fi
  choose_auth_method

  local x11=0
  read -rp "$(echo -e "${C_CYAN}Enable X11 forwarding for this host (run GUI apps over ssh)? [y/N]: ${C_RESET}")" x11ans
  [[ "$x11ans" =~ ^[Yy]$ ]] && x11=1

  read -rp "$(echo -e "${C_CYAN}Persist this host to ~/.ssh/config for future sessions? [Y/n]: ${C_RESET}")" persist
  if [[ "$persist" =~ ^[Nn]$ ]]; then
    log_info "Not saving — one-off connection."
    local target="${usr}@${hn}"
    [ "$METHOD" = "password" ] && offer_passwordless "$target"
    connect_ephemeral "$hn" "$usr" "$IDENTITY" "$x11"
    return
  fi

  if alias_exists "$alias"; then
    log_error "Alias '$alias' already exists in $SSH_CONFIG."
    log_dim "  Tip: edit $SSH_CONFIG or use a different host; not overwriting."
    exec "${SHELL:-bash}"
  fi
  if ! append_managed_host "$alias" "$hn" "$usr" "$IDENTITY" "$x11"; then
    log_warn "Failed to write $SSH_CONFIG (permission denied or not writable)."
    log_dim "  Falling back to one-off connect (not persisted)."
    log_dim "  Fix: sudo chown $USER:$USER $SSH_CONFIG && chmod 600 $SSH_CONFIG"
    # Don't drop to shell — still try to connect via ephemeral so password prompt appears
    [ "$METHOD" = "password" ] && offer_passwordless "${usr}@${hn}" || true
    # Ensure pane stays open on failure via connect_ephemeral's own handler
    connect_ephemeral "$hn" "$usr" "$IDENTITY" "$x11"
    return
  fi
  log_ok "Added Host '${C_BOLD}$alias${C_RESET}' ${C_DIM}→ $usr@$hn${C_RESET} to $SSH_CONFIG."
  log_dim "  It'll show up in the menu (prefix+c if bound, or just run scpt)."
  [ "$x11" = "1" ] && log_dim "  X11 forwarding enabled (ForwardX11/ForwardX11Trusted in $SSH_CONFIG)."
  if [ "$METHOD" = "password" ]; then
    # Ask after save — offer to make it passwordless, but don't hide password prompt if they decline
    offer_passwordless "$alias" || true
  fi
  read -rp "$(echo -e "${C_CYAN}Connect now? [Y/n]: ${C_RESET}")" ans
  if [[ ! "$ans" =~ ^[Nn]$ ]]; then
    connect "$alias"
  else
    exec "${SHELL:-bash}"
  fi
}

add_host() {
  local target hn usr alias
  echo -e "${C_BOLD}Add new remote${C_RESET} ${C_DIM}— enter as user@hostname (e.g. ${USER}@$(hostname -s) or ubuntu@192.168.1.10)${C_RESET}"
  read -rp "$(echo -e "${C_CYAN}Remote [${USER}@hostname]: ${C_RESET}")" target
  target="$(echo "${target:-}" | xargs)"
  [ -z "$target" ] && {
    log_info "Cancelled."
    exec "${SHELL:-bash}"
  }
  if [[ "$target" == *"@"* ]]; then
    usr="${target%%@*}"
    hn="${target#*@}"
  else
    hn="$target"
    usr="$USER"
    log_dim "No user given → using '$usr@$hn'."
  fi
  hn="$(echo "$hn" | xargs)"
  usr="$(echo "$usr" | xargs)"
  if [ -z "$hn" ] || [ -z "$usr" ]; then
    log_error "Invalid target. Need user@host."
    exec "${SHELL:-bash}"
  fi
  if [[ "$hn" =~ ^[0-9.]+$ ]]; then
    alias="$hn"
  else
    alias="${hn%%.*}"
  fi
  # Host alias must be single token (no spaces); keep dots for IPs, else sanitize
  alias="${alias//[^A-Za-z0-9._-]/-}"
  # Also sanitize dots were kept for IP, but Host with slashes etc already handled
  [ -z "$alias" ] && alias="$hn"
  if alias_exists "$alias"; then
    local alt="${usr}-${alias}"
    alt="${alt//[^A-Za-z0-9._-]/-}"
    log_warn "alias '$alias' already exists → using '$alt'."
    alias="$alt"
    if alias_exists "$alias"; then
      log_error "Alias '$alias' also exists — please edit $SSH_CONFIG manually."
      exec "${SHELL:-bash}"
    fi
  fi
  log_info "Using alias '${C_BOLD}$alias${C_RESET}' for ${C_BOLD}$usr@$hn${C_RESET} ${C_DIM}(edit $SSH_CONFIG to rename)${C_RESET}."
  probe_ssh_server "$usr" "$hn"
  finalize_add "$alias" "$hn" "$usr"
}

# ── nmap discovery ──────────────────────────────────────────────────
scan_network() {
  if ! command -v nmap >/dev/null; then
    log_error "nmap isn't installed. Install it (e.g. 'sudo apt install nmap') and try again."
    exec "${SHELL:-bash}"
  fi

  local default_subnet
  default_subnet="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4; exit}')"
  read -rp "$(echo -e "${C_CYAN}Subnet to scan [${default_subnet:-e.g. 192.168.1.0/24}]: ${C_RESET}")" subnet
  subnet="${subnet:-$default_subnet}"
  [ -z "$subnet" ] && {
    log_info "No subnet given."
    exec "${SHELL:-bash}"
  }

  log_info "Scanning ${C_BOLD}$subnet${C_RESET} ${C_DIM}(this can take a bit)${C_RESET}..."
  local results=()
  while IFS= read -r line; do results+=("$line"); done \
    < <(nmap -sn "$subnet" 2>/dev/null | sed -n 's/^Nmap scan report for //p')

  if [ "${#results[@]}" -eq 0 ]; then
    log_warn "No devices found."
    exec "${SHELL:-bash}"
  fi

  echo -e "${C_BOLD}Found ${#results[@]} device(s):${C_RESET}"
  local i
  for i in "${!results[@]}"; do
    printf '  ${C_CYAN}%d)${C_RESET} %s\n' "$((i + 1))" "${results[$i]}"
  done
  read -rp "$(echo -e "${C_CYAN}Add one as a remote? (number, or Enter to cancel): ${C_RESET}")" pick
  [[ "$pick" =~ ^[0-9]+$ ]] || {
    log_info "Cancelled."
    exec "${SHELL:-bash}"
  }
  local idx=$((pick - 1))
  [ "$idx" -ge 0 ] && [ "$idx" -lt "${#results[@]}" ] || {
    log_error "Invalid pick."
    exec "${SHELL:-bash}"
  }

  local chosen="${results[$idx]}" ip
  if [[ "$chosen" =~ \(([0-9.]+)\)$ ]]; then
    ip="${BASH_REMATCH[1]}"
  else
    ip="$chosen"
  fi
  local alias usr
  read -rp "$(echo -e "${C_CYAN}Alias for this host [$ip]: ${C_RESET}")" alias
  alias="${alias:-$ip}"
  read -rp "$(echo -e "${C_CYAN}Username for $ip [$USER]: ${C_RESET}")" usr
  usr="${usr:-$USER}"
  # Probe before finalize so auth chooser is informed
  PROBE_HINT=""; PROBE_METHODS=""
  probe_ssh_server "$usr" "$ip"
  finalize_add "$alias" "$ip" "$usr"
}

# ── entry point ───────────────────────────────────────────────────────
case "${1:-}" in
--menu) build_menu ;;
--transfer-here) transfer_here ;;
--list|-l|--remotes) list_all ;;
--connect) connect "${2:-}" ;;
--connect-ephemeral) connect_ephemeral "${2:-}" "${3:-}" "${4:-}" "${5:-0}" ;;
--connect-docker) connect_docker "${2:-}" "${3:-}" ;;
--reload-pane) reload_pane ;;
--pane-dropped-notice) pane_dropped_notice ;;
--smart-split) smart_split "${2:-h}" ;;
--smart-new-window) smart_new_window ;;
--add) add_host ;;
--scan) scan_network ;;
--bind|--install) install_binding --yes ;;
--unbind) uninstall_binding ;;
--basics)
  require_tmux || exit 1
  if [ -z "${TMUX:-}" ]; then
    log_error "Not inside tmux — nothing to apply --basics to."
    exit 1
  fi
  ensure_tmux_basics
  log_ok "Applied statusbar/colors to this tmux server."
  ;;
--yes|--force) install_binding --yes ;;
--no|--no-bind) install_binding --no ;;
--help|-h)
  echo -e "${C_BOLD}Usage:${C_RESET} $SCRIPT [${C_CYAN}--menu|--connect <alias>|--add|--scan|--bind|--unbind${C_RESET}]"
  echo -e "  ${C_BOLD}(no args)${C_RESET}  Inside tmux: ${C_GREEN}show menu${C_RESET} for this session; outside tmux: launch tmux+bind"
  echo -e "  ${C_CYAN}--menu${C_RESET}      Show menu (used by tmux binding)"
  echo -e "  ${C_CYAN}-l, --list${C_RESET}    List tmux sessions, docker containers, saved remotes & active connections"
  echo -e "  ${C_CYAN}--transfer-here${C_RESET}  Full-pane file transfer (prefix+T): drop a file or fzf, sent to wherever this pane is connected"
  echo -e "  ${C_CYAN}--add${C_RESET}       Add new remote — prompts for ${C_BOLD}user@host${C_RESET}, probes server, asks auth"
  echo -e "  ${C_CYAN}--scan${C_RESET}      Scan subnet with nmap to pick a host"
  echo -e "  ${C_CYAN}--connect-docker${C_RESET} <name>  Attach to a running docker container (also listed in the menu)"
  echo -e "  ${C_CYAN}--bind${C_RESET}      Install ${C_BOLD}prefix+c${C_RESET} smart + ${C_BOLD}prefix+T${C_RESET} transfer + ${C_BOLD}prefix+R${C_RESET} reload + ${C_BOLD}prefix+% / prefix+\"${C_RESET} multiplex ${C_DIM}(ssh pane→new ssh pane via ControlMaster)${C_RESET}"
  echo -e "  ${C_CYAN}--unbind${C_RESET}    Restore ${C_BOLD}prefix+c/T/R/%/\"${C_RESET} to defaults"
  echo -e "  ${C_CYAN}--basics${C_RESET}    Apply statusbar/colors/mouse etc to the ${C_BOLD}current${C_RESET} tmux server ${C_DIM}(must be run inside tmux)${C_RESET}"
  echo -e "  ${C_CYAN}--help${C_RESET}      Show this help"
  echo ""
  echo -e "${C_DIM}Multiplexing: after ssh via menu, any split from that pane auto-ssh's the same host${C_RESET}"
  echo -e "${C_DIM}  (ControlMaster reuses the TCP connection — no re-auth). Local splits stay local.${C_RESET}"
  echo -e "${C_DIM}Tip: to auto-bind new tmux servers, add to ~/.bashrc:${C_RESET}"
  echo -e "  ${C_DIM}[ -n \"\$TMUX\" ] && bash \"$SCRIPT\" --bind >/dev/null${C_RESET}"
  echo -e "${C_DIM}Remote tmux: used by default for persistence when installed remotely; its status${C_RESET}"
  echo -e "${C_DIM}  line is forced off, so only this (local) status bar shows.${C_RESET}"
  echo -e "${C_DIM}  Set ${C_BOLD}SCPT_REMOTE_TMUX=0${C_RESET} to force plain ssh instead (no remote persistence).${C_RESET}"
  echo -e "${C_DIM}Dropped connections: prefix+R reconnects the current pane in place${C_RESET}"
  echo -e "${C_DIM}X11: when adding a host you'll be asked whether to enable X11 forwarding${C_RESET}"
  echo -e "${C_DIM}  (persisted as ForwardX11/ForwardX11Trusted in ~/.ssh/config; one-off hosts get -X)${C_RESET}"
  ;;
*)
  if [ -n "${TMUX:-}" ]; then
    # Inside tmux: default is to show menu for this session (clean, no side-effects)
    build_menu
  else
    # Outside tmux: default is to bootstrap tmux and install binding
    install_binding "${1:-}"
  fi
  ;;
esac
