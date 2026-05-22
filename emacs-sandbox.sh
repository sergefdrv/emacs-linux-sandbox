#!/bin/bash
# emacs-sandbox-managed
#
# PGTK Emacs sandboxed launcher (bubblewrap).
#
# Runs the apt-installed PGTK Emacs (default /usr/bin/emacs) inside a
# bubblewrap sandbox that limits filesystem access to the workspace
# directory, ~/.emacs.d, ~/.emacs (if present), and a small set of
# read-only tool installs and
# shell rc files. The Wayland socket is bound through so the PGTK build
# can talk directly to the compositor; DISPLAY is unset to deny any
# Xwayland fallback.
#
# Installed at ~/.local/bin/emacs by emacs-sandbox-setup.sh. On distros
# where ~/.local/bin precedes /usr/bin on PATH (Ubuntu default), this
# shadows /usr/bin/emacs for shell invocations; the .desktop overrides
# installed alongside cover GUI launchers.
#
# The "# emacs-sandbox-managed" marker on line 2 lets setup detect
# previously-installed wrappers when re-running.

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
if [ -f "$SCRIPT_DIR/emacs-sandbox-common.sh" ]; then
    source "$SCRIPT_DIR/emacs-sandbox-common.sh"
else
    source "$HOME/.local/opt/emacs-sandbox/emacs-sandbox-common.sh"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config not found at: $CONFIG_FILE" >&2
    echo "Run emacs-sandbox-setup.sh first." >&2
    exit 1
fi
source "$CONFIG_FILE"

# ── Sanity checks ────────────────────────────────────────────────────
if [[ ! -x "$EMACS_BIN" ]]; then
    echo "Error: emacs binary missing or not executable at $EMACS_BIN" >&2
    echo "Re-run emacs-sandbox-setup.sh to reconfigure." >&2
    exit 1
fi
if [[ ! -f "$SECCOMP_BPF" ]]; then
    echo "Error: seccomp BPF blob missing at $SECCOMP_BPF" >&2
    echo "Re-run emacs-sandbox-setup.sh to regenerate it." >&2
    exit 1
fi
if ! command -v bwrap &>/dev/null; then
    echo "Error: bubblewrap (bwrap) is not installed." >&2
    exit 1
fi

# Ensure host-side directories used by writable binds below exist.
# Idempotent.
mkdir -p \
    "$HOME/.emacs.d" \
    "$HOME/.cargo/registry" \
    "$HOME/.npm/_cacache" \
    "$HOME/.local/share/pnpm/store" \
    "$HOME/.cache/pip" \
    "$HOME/go/pkg/mod" \
    "$HOME/.cache/go-build"

# Emacs server socket dir: the sandboxed Emacs creates its server socket
# at $XDG_RUNTIME_DIR/emacs/server. Without a host-side bind it lives in
# the sandbox's tmpfs view of /run and is invisible to host emacsclient.
USER_ID="$(id -u)"
XDG_DIR="${XDG_RUNTIME_DIR:-/run/user/$USER_ID}"
mkdir -p "$XDG_DIR/emacs"
chmod 700 "$XDG_DIR/emacs"

# ── Effective workspace (writable root) ──────────────────────────────
# The configured WORKSPACE_DIR is the broadest the sandbox will ever allow.
# EMACS_SANDBOX_WORKSPACE=... can narrow it (never widen); it must be a
# subdirectory of (or equal to) WORKSPACE_DIR.
effective_workspace="$WORKSPACE_DIR"
if [[ -n "${EMACS_SANDBOX_WORKSPACE:-}" ]]; then
    override="$(readlink -f "$EMACS_SANDBOX_WORKSPACE")"
    if [[ "$override" == "$WORKSPACE_DIR" || "$override/" == "$WORKSPACE_DIR/"* ]]; then
        effective_workspace="$override"
    else
        echo "Error: EMACS_SANDBOX_WORKSPACE ($override) is not inside WORKSPACE_DIR ($WORKSPACE_DIR)." >&2
        echo "       The sandbox can only narrow, never widen, the configured workspace." >&2
        exit 1
    fi
fi

# ── Working directory inside the sandbox ─────────────────────────────
# Use $PWD if it's bound (workspace or ~/.emacs.d). Otherwise:
#   - With a terminal on stderr (interactive shell launch), bail with a
#     clear error -- silently dropping the user into the workspace would
#     be a surprising "where did I just open?" experience.
#   - Without a terminal (desktop launcher: stderr goes to the journal),
#     silently start in the workspace root. Desktop icons must work.
if [[ "$PWD" == "$effective_workspace" || "$PWD/" == "$effective_workspace/"* ]]; then
    sandbox_cwd="$PWD"
elif [[ "$PWD" == "$HOME/.emacs.d" || "$PWD/" == "$HOME/.emacs.d/"* ]]; then
    sandbox_cwd="$PWD"
elif [[ -t 2 ]]; then
    echo "Error: current directory $PWD is not exposed inside the sandbox." >&2
    echo "       cd into $effective_workspace (or under ~/.emacs.d) first." >&2
    exit 1
else
    sandbox_cwd="$effective_workspace"
fi

# ── xdg-dbus-proxy (filtered session bus for portals + notifications) ─
PROXY_DIR=
proxy_pid=
if command -v xdg-dbus-proxy &>/dev/null && [[ -n "$DBUS_SESSION_BUS_ADDRESS" ]]; then
    PROXY_DIR="$XDG_DIR/emacs-sandbox.$$"
    mkdir -p "$PROXY_DIR"
    chmod 700 "$PROXY_DIR"
    xdg-dbus-proxy "$DBUS_SESSION_BUS_ADDRESS" "$PROXY_DIR/bus" \
        --filter \
        --talk=org.freedesktop.portal.Desktop \
        --talk=org.freedesktop.portal.OpenURI \
        --talk=org.freedesktop.Notifications \
        &
    proxy_pid=$!
    cleanup() {
        if [[ -n "$proxy_pid" ]]; then
            kill "$proxy_pid" 2>/dev/null || true
        fi
        if [[ -n "$PROXY_DIR" ]]; then
            rm -rf "$PROXY_DIR" || true
        fi
    }
    trap cleanup EXIT INT TERM
    # Wait briefly for the proxy socket to appear (up to ~2s).
    for _ in $(seq 1 20); do
        [[ -S "$PROXY_DIR/bus" ]] && break
        sleep 0.1
    done
    if [[ ! -S "$PROXY_DIR/bus" ]]; then
        echo "Warning: xdg-dbus-proxy did not produce a socket; portal calls will fail." >&2
        PROXY_DIR=
    fi
else
    echo "Notice: xdg-dbus-proxy not available; sandbox will run without a session bus." >&2
fi

# ── Build bwrap argument list ────────────────────────────────────────
ARGS=(
    # Base read-only system layout
    --ro-bind     /usr  /usr
    --ro-bind-try /bin  /bin
    --ro-bind-try /sbin /sbin
    --ro-bind-try /lib   /lib
    --ro-bind-try /lib32 /lib32
    --ro-bind-try /lib64 /lib64
    --ro-bind     /etc  /etc
    --proc        /proc
    --dev         /dev
    --tmpfs       /tmp
    --tmpfs       /run

    # Re-expose resolver state so /etc/resolv.conf's symlink chain resolves
    # (Ubuntu/systemd-resolved, NetworkManager, openresolv).
    --ro-bind-try /run/systemd/resolve /run/systemd/resolve
    --ro-bind-try /run/NetworkManager  /run/NetworkManager
    --ro-bind-try /run/resolvconf      /run/resolvconf

    # Blanket-tmpfs $HOME, then re-expose only what's needed
    --tmpfs "$HOME"

    # Writable: workspace (possibly narrowed) + Emacs' own state
    --bind "$effective_workspace" "$effective_workspace"
    --bind "$HOME/.emacs.d"       "$HOME/.emacs.d"
)

# Legacy single-file init (optional). Bind read-write so you can edit it
# from inside Emacs; skip entirely if absent.
if [[ -f "$HOME/.emacs" ]]; then
    ARGS+=(--bind "$HOME/.emacs" "$HOME/.emacs")
fi

ARGS+=(
    # Read-only tool installs (managed outside the sandbox)
    --ro-bind-try "$HOME/.local/bin"        "$HOME/.local/bin"
    --ro-bind-try "$HOME/.local/share/pnpm" "$HOME/.local/share/pnpm"
    --ro-bind-try "$HOME/.cargo"  "$HOME/.cargo"
    --ro-bind-try "$HOME/.rustup" "$HOME/.rustup"
    --ro-bind-try "$HOME/.nvm"    "$HOME/.nvm"
    --ro-bind-try "$HOME/.pyenv"  "$HOME/.pyenv"
    --ro-bind-try "$HOME/go"      "$HOME/go"

    # Writable package-manager caches (shared with host).
    # The package managers verify content integrity against lockfiles, so
    # sharing these with the host does not let a sandboxed process forge
    # cache contents. Adding these RW carve-outs makes M-x compile with
    # cargo / npm / pnpm / pip / go work inside the sandbox without falling
    # back to "no cache" or failing on write.
    --bind "$HOME/.cargo/registry"          "$HOME/.cargo/registry"
    --bind "$HOME/.npm/_cacache"            "$HOME/.npm/_cacache"
    --bind "$HOME/.local/share/pnpm/store"  "$HOME/.local/share/pnpm/store"
    --bind "$HOME/.cache/pip"               "$HOME/.cache/pip"
    --bind "$HOME/go/pkg/mod"               "$HOME/go/pkg/mod"
    --bind "$HOME/.cache/go-build"          "$HOME/.cache/go-build"

    # Read-only shell rc + git config (so M-x shell / vterm / ansi-term
    # subshells feel familiar)
    --ro-bind-try "$HOME/.gitconfig"    "$HOME/.gitconfig"
    --ro-bind-try "$HOME/.bashrc"       "$HOME/.bashrc"
    --ro-bind-try "$HOME/.profile"      "$HOME/.profile"
    --ro-bind-try "$HOME/.bash_profile" "$HOME/.bash_profile"
    --ro-bind-try "$HOME/.zshrc"        "$HOME/.zshrc"
    --ro-bind-try "$HOME/.zshenv"       "$HOME/.zshenv"
    --ro-bind-try "$HOME/.inputrc"      "$HOME/.inputrc"

    # Wayland (PGTK Emacs talks to the compositor directly; the socket
    # must be bound rw because the protocol is a round-trip stream).
    --bind "$XDG_DIR/wayland-0"      "$XDG_DIR/wayland-0"
    --bind "$XDG_DIR/wayland-0.lock" "$XDG_DIR/wayland-0.lock"

    # Emacs server socket directory. Bound rw so M-x server-start inside
    # the sandbox produces a socket that host `emacsclient` can reach.
    # Files opened via emacsclient still have to live within the
    # sandbox's writable scope (workspace or ~/.emacs.d) for the server
    # to actually read them.
    --bind "$XDG_DIR/emacs" "$XDG_DIR/emacs"

    # Fonts (so the sandboxed Emacs sees user-installed fonts and any
    # fontconfig overrides). Read-only -- the sandbox should not be
    # rewriting font caches.
    --ro-bind-try "$HOME/.local/share/fonts" "$HOME/.local/share/fonts"
    --ro-bind-try "$HOME/.config/fontconfig" "$HOME/.config/fontconfig"

    # GTK / GNOME desktop preferences. PGTK Emacs reads these via
    # GSettings, which mmaps ~/.config/dconf/user; without this bind the
    # sandbox falls back to GTK defaults (Adwaita theme, no text-scaling
    # factor, no dark mode, default cursor, system font ignored).
    # Read-only -- live updates from gnome-control-center while Emacs
    # is running are not propagated; restart Emacs after changing
    # settings on the host.
    --ro-bind-try "$HOME/.config/dconf"   "$HOME/.config/dconf"
    --ro-bind-try "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-3.0"
    --ro-bind-try "$HOME/.config/gtk-4.0" "$HOME/.config/gtk-4.0"

    # xdg-open shim directory (added to PATH below so packages that
    # shell out to xdg-open route through the host portal).
    --ro-bind "$INSTALL_DIR/bin" "$INSTALL_DIR/bin"

    --setenv HOME            "$HOME"
    --setenv USER            "${USER:-$(id -un)}"
    --setenv PATH            "$INSTALL_DIR/bin:$HOME/.local/bin:$PATH"
    --setenv BROWSER         "$INSTALL_DIR/bin/xdg-open"
    --setenv EDITOR          "${EDITOR:-}"
    --setenv LANG            "${LANG:-}"
    --setenv XDG_RUNTIME_DIR "$XDG_DIR"
    --setenv TMPDIR          "/tmp"

    # Force Wayland; refuse Xwayland fallback. PGTK Emacs respects
    # GDK_BACKEND, and unsetting DISPLAY denies it any X server even if
    # one is reachable. NO_AT_BRIDGE silences the at-spi accessibility
    # bus chatter (no a11y bus inside the sandbox).
    --setenv   GDK_BACKEND       wayland
    --setenv   MOZ_ENABLE_WAYLAND 1
    --setenv   NO_AT_BRIDGE      1
    --unsetenv DISPLAY

    --chdir "$sandbox_cwd"

    --unshare-all --share-net
    --die-with-parent
    --new-session
    --cap-drop ALL
)

# Forward whichever LC_* category overrides the user has set on the host
# (LC_ALL, LC_CTYPE, LC_COLLATE, ...). The set varies per system, so enumerate
# from the live environment rather than hard-coding the list.
for _lc_var in ${!LC_*}; do
    ARGS+=(--setenv "$_lc_var" "${!_lc_var}")
done
unset _lc_var

# Filtered session bus, only if the proxy came up.
if [[ -n "$PROXY_DIR" && -S "$PROXY_DIR/bus" ]]; then
    ARGS+=(
        --bind   "$PROXY_DIR/bus" "$XDG_DIR/bus"
        --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$XDG_DIR/bus"
    )
fi

# Optional site-local extension hook (persistent equivalent of the
# $EMACS_SANDBOX_EXTRA_ARGS env var below).  Plain text: one bwrap
# directive per line, `#` starts a comment, blank lines ignored.
# Variables ($HOME, $INSTALL_DIR, ...) are expanded.  Lives in
# $INSTALL_DIR so it's outside the sandbox's writable scope.
# See README ("Extending the sandbox") for examples.
LOCAL_PROFILE="$INSTALL_DIR/emacs-sandbox.local"
if [[ -f "$LOCAL_PROFILE" ]]; then
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _line="${_line%%#*}"
        read -r _line <<<"$_line" || true   # trim leading/trailing whitespace
        [[ -z "$_line" ]] && continue
        # eval: enables ${HOME}-style expansion and quoting; trust model
        # is the same as sourcing -- file lives in $INSTALL_DIR.
        eval "ARGS+=( $_line )"
    done < "$LOCAL_PROFILE"
    unset _line
fi

# Optional per-invocation extension hook: extra bwrap args from
# $EMACS_SANDBOX_EXTRA_ARGS.  Space-separated, IFS-split.  Use sparingly --
# each entry widens the sandbox.
if [[ -n "${EMACS_SANDBOX_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA=( $EMACS_SANDBOX_EXTRA_ARGS )
    ARGS+=( "${EXTRA[@]}" )
fi

# ── Seccomp BPF: open as FD, pass to bwrap via --seccomp <fd> ────────
exec {seccomp_fd}<"$SECCOMP_BPF"
ARGS+=(--seccomp "$seccomp_fd")

# ── Exec ─────────────────────────────────────────────────────────────
# Invoke the real Emacs binary by absolute path. The wrapper at
# $HOME/.local/bin/emacs (this script) is hidden inside the sandbox
# because $HOME is a tmpfs and $HOME/.local/bin is re-bound read-only
# from the host -- but $EMACS_BIN points at /usr/bin/emacs (or wherever
# the user configured), which is reachable through the /usr ro-bind.
exec bwrap "${ARGS[@]}" "$EMACS_BIN" "$@"
