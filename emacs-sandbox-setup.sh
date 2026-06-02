#!/bin/bash
#
# PGTK Emacs Sandbox Setup (run once, or re-run to update).
#
# Checks prerequisites, validates that $EMACS_BIN is a PGTK build, warns
# if the current desktop session is not Wayland, generates the seccomp
# BPF blob, installs the xdg-open shim, installs override .desktop files
# under ~/.local/share/applications/, and installs the wrapper at
# ~/.local/bin/emacs.
#

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
source "$SCRIPT_DIR/emacs-sandbox-common.sh"

# ── Parse args ───────────────────────────────────────────────────────
UNINSTALL=false
# "" = unresolved (fall through to env/config/prompt); true/false = forced by flag.
nested_flag=""
for arg in "$@"; do
    case "$arg" in
        --uninstall)            UNINSTALL=true ;;
        --no-nested-sandbox)    nested_flag=false ;;
        --allow-nested-sandbox) nested_flag=true ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--uninstall] [--allow-nested-sandbox | --no-nested-sandbox]

  --uninstall   Remove the sandbox: \$INSTALL_DIR, the wrapper at
                \$WRAPPER_PATH (only if it is ours), and the override
                .desktop files under ~/.local/share/applications/ that
                carry our marker. Preserves ~/.emacs.d and ~/.emacs.
  --allow-nested-sandbox / --no-nested-sandbox
                Whether the generated seccomp BPF leaves the mount family
                (mount/umount2/pivot_root) unblocked so a nested bubblewrap
                sandbox (one launched from a terminal inside Emacs) can run.
                Default: allow. The choice persists in the config; re-runs
                reuse it.

Environment:
  WORKSPACE_DIR  Workspace directory bound rw inside the sandbox.
                 Prompted if unset.
  EMACS_BIN      Path to the real Emacs binary to invoke inside the
                 sandbox. Default: /usr/bin/emacs. Must be a PGTK build
                 ((featurep 'pgtk) returns t).
  EMACS_SANDBOX_ALLOW_NESTED  1/true/yes or 0/false/no -- non-interactive
                 equivalent of the --[no-]nested-sandbox flags.
EOF
            exit 0
            ;;
    esac
done

# Setup prompts for the workspace dir, migration, and uninstall confirmation;
# bail out early on a non-tty stdin/stdout rather than silently accepting
# defaults (or, worse, mass-deleting on --uninstall).
if [[ ! -t 0 || ! -t 1 ]]; then
    echo "Error: $0 must be run interactively (stdin and stdout must be a TTY)." >&2
    exit 1
fi

# ── Uninstall path ───────────────────────────────────────────────────
if "$UNINSTALL"; then
    # Safety: refuse to operate on suspicious values.
    if [[ -z "$INSTALL_DIR" || "$INSTALL_DIR" != "$HOME"/* ]]; then
        echo "Error: refusing to act on INSTALL_DIR='$INSTALL_DIR' (expected under \$HOME)." >&2
        exit 1
    fi

    plan=()
    [[ -d "$INSTALL_DIR" ]] && plan+=("$INSTALL_DIR/")
    if [[ -e "$WRAPPER_PATH" || -L "$WRAPPER_PATH" ]]; then
        if emacs_is_our_wrapper "$WRAPPER_PATH"; then
            plan+=("$WRAPPER_PATH (sandbox wrapper)")
        else
            echo "Note: $WRAPPER_PATH exists but does NOT carry our marker;" >&2
            echo "      leaving it alone (looks like a foreign emacs install)." >&2
            echo "" >&2
        fi
    fi
    # Collect override .desktop files carrying our marker.
    desktop_dir="$HOME/.local/share/applications"
    desktop_victims=()
    if [[ -d "$desktop_dir" ]]; then
        shopt -s nullglob
        for d in "$desktop_dir"/emacs*.desktop "$desktop_dir"/org.gnu.emacs*.desktop; do
            emacs_desktop_is_ours "$d" && desktop_victims+=("$d")
        done
        shopt -u nullglob
    fi
    for d in "${desktop_victims[@]}"; do
        plan+=("$d (desktop launcher override)")
    done

    if (( ${#plan[@]} == 0 )); then
        echo "Nothing to uninstall."
        exit 0
    fi

    echo "Will remove:"
    for p in "${plan[@]}"; do
        echo "  - $p"
    done
    echo ""
    echo "  ~/.emacs.d and ~/.emacs are preserved."
    echo ""

    read -rp "Proceed? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

    # Best-effort removal: each step is independent; we report failures at the
    # end rather than aborting on the first error.
    failures=()
    _try_rm() {
        local err
        if ! err="$(rm -rf "$1" 2>&1)"; then
            failures+=("$1: $err")
        fi
    }
    [[ -d "$INSTALL_DIR" ]] && _try_rm "$INSTALL_DIR"
    if [[ -e "$WRAPPER_PATH" || -L "$WRAPPER_PATH" ]] && emacs_is_our_wrapper "$WRAPPER_PATH"; then
        _try_rm "$WRAPPER_PATH"
    fi
    for d in "${desktop_victims[@]}"; do
        _try_rm "$d"
    done
    if [[ ${#desktop_victims[@]} -gt 0 ]]; then
        command -v update-desktop-database >/dev/null \
            && update-desktop-database "$desktop_dir" >/dev/null 2>&1 \
            || true
    fi

    if (( ${#failures[@]} == 0 )); then
        echo "Uninstall complete."
        exit 0
    fi
    echo "" >&2
    echo "Uninstall finished with errors:" >&2
    for f in "${failures[@]}"; do
        echo "  $f" >&2
    done
    exit 1
fi

# ── Prereqs ──────────────────────────────────────────────────────────
missing=()
for cmd in bwrap xdg-dbus-proxy gdbus python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
    echo "Error: missing required commands: ${missing[*]}" >&2
    echo "" >&2
    echo "Install on Debian/Ubuntu:" >&2
    echo "  sudo apt install bubblewrap xdg-dbus-proxy libglib2.0-bin python3 python3-seccomp" >&2
    echo "Install on Fedora:" >&2
    echo "  sudo dnf install bubblewrap xdg-dbus-proxy glib2 python3 python3-libseccomp" >&2
    echo "Install on Arch:" >&2
    echo "  sudo pacman -S bubblewrap xdg-desktop-portal glib2 python python-libseccomp" >&2
    exit 1
fi

if ! check_libseccomp_python; then
    echo "" >&2
    echo "Install on Debian/Ubuntu: sudo apt install python3-seccomp" >&2
    echo "Install on Fedora:        sudo dnf install python3-libseccomp" >&2
    echo "Install on Arch:          sudo pacman -S python-libseccomp" >&2
    exit 1
fi

# bwrap must be able to create unprivileged user namespaces -- this is the
# single biggest source of "it doesn't work on Ubuntu 24.04" reports, so
# preflight it here rather than letting the install step fail opaquely.
echo "Checking that bwrap can create user namespaces..."
if ! check_bwrap_userns; then
    print_userns_remediation
    exit 1
fi
echo "  OK."
echo ""

# ── Resolve and validate EMACS_BIN ───────────────────────────────────
EMACS_BIN="${EMACS_BIN:-/usr/bin/emacs}"
if [[ ! -x "$EMACS_BIN" ]]; then
    echo "Error: EMACS_BIN=$EMACS_BIN is not executable." >&2
    echo "Install: sudo apt install emacs-pgtk" >&2
    exit 1
fi

echo "Verifying that $EMACS_BIN is a PGTK build..."
if ! "$EMACS_BIN" --batch --eval '(unless (featurep (quote pgtk)) (kill-emacs 1))' 2>/dev/null; then
    echo "Error: $EMACS_BIN is not a PGTK build." >&2
    echo "Install: sudo apt install emacs-pgtk" >&2
    echo "Or:      EMACS_BIN=/path/to/your/pgtk/emacs ./emacs-sandbox-setup.sh" >&2
    exit 1
fi
echo "  OK."
echo ""

# Wayland session check (warning, not fatal): the runtime launcher sets
# GDK_BACKEND=wayland and unsets DISPLAY, so an X11-only session will
# fail to open a window. PGTK Emacs needs a live compositor.
if [[ "$XDG_SESSION_TYPE" != "wayland" ]]; then
    echo "Warning: \$XDG_SESSION_TYPE=$XDG_SESSION_TYPE (expected 'wayland')." >&2
    echo "  The sandbox sets GDK_BACKEND=wayland and unbinds DISPLAY; sandboxed" >&2
    echo "  Emacs will fail to open windows on an X11-only session." >&2
    echo ""
fi

# ── Workspace ────────────────────────────────────────────────────────
if [[ -z "$WORKSPACE_DIR" ]]; then
    read -rp "Enter workspace directory [$HOME/proj]: " WORKSPACE_DIR
    WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/proj}"
fi
mkdir -p "$WORKSPACE_DIR"
WORKSPACE_DIR="$(readlink -f "$WORKSPACE_DIR")"

# ── Nested-sandbox seccomp policy ────────────────────────────────────
# The base deny-list leaves mount/umount2/pivot_root unblocked so a nested
# bubblewrap sandbox (one launched from a terminal inside Emacs) can run.
# Opt out to restore the hardened default that blocks them.
# Resolution precedence:
#   flag (--[no-]nested-sandbox) > env (EMACS_SANDBOX_ALLOW_NESTED)
#     > existing config value (re-runs) > interactive prompt (default yes).
NESTED_BLOCK_SYSCALLS="mount umount2 pivot_root"
ALLOW_NESTED_SANDBOX="$nested_flag"
if [[ -z "$ALLOW_NESTED_SANDBOX" && -n "${EMACS_SANDBOX_ALLOW_NESTED:-}" ]]; then
    case "$EMACS_SANDBOX_ALLOW_NESTED" in
        1|true|yes|TRUE|YES)  ALLOW_NESTED_SANDBOX=true ;;
        0|false|no|FALSE|NO)  ALLOW_NESTED_SANDBOX=false ;;
        *) echo "Warning: ignoring unrecognised EMACS_SANDBOX_ALLOW_NESTED='$EMACS_SANDBOX_ALLOW_NESTED'." >&2 ;;
    esac
fi
if [[ -z "$ALLOW_NESTED_SANDBOX" && -f "$CONFIG_FILE" ]]; then
    # Reuse the prior choice silently on re-run.
    ALLOW_NESTED_SANDBOX="$(source "$CONFIG_FILE" 2>/dev/null && printf '%s' "${ALLOW_NESTED_SANDBOX:-}")"
fi
if [[ -z "$ALLOW_NESTED_SANDBOX" ]]; then
    echo "A nested bubblewrap sandbox (one launched from a terminal inside"
    echo "Emacs) can only run if the mount/umount2/pivot_root syscalls are left"
    echo "unblocked in the seccomp filter. This widens kernel attack surface but"
    echo "does not weaken this sandbox's filesystem boundary (see the README's"
    echo "'Nested sandboxing' section)."
    read -rp "Support nested sandboxing? [Y/n] " _ans
    if [[ -n "$_ans" && ! "$_ans" =~ ^[Yy] ]]; then
        ALLOW_NESTED_SANDBOX=false
    else
        ALLOW_NESTED_SANDBOX=true
    fi
    echo ""
fi

# ── Required directories ─────────────────────────────────────────────
mkdir -p "$INSTALL_DIR" \
         "$INSTALL_DIR/bin" \
         "$HOME/.local/bin" \
         "$HOME/.emacs.d"

# ── Copy support files into $INSTALL_DIR (so re-runs work standalone) ─
cp "$SCRIPT_DIR/emacs-sandbox-common.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/gen-seccomp-bpf.py"      "$INSTALL_DIR/"
cp "$SCRIPT_DIR/emacs.seccomp.deny.list" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/gen-seccomp-bpf.py"

# ── Handle pre-existing ~/.local/bin/emacs ───────────────────────────
# If a non-sandboxed emacs already lives at the wrapper path (e.g. the
# user previously installed a hand-rolled launcher there), offer to move
# it aside before we overwrite.
existing="$(find_foreign_emacs || true)"
if [[ -n "$existing" && "$existing" == "$HOME/.local/bin/emacs" ]]; then
    backup="$INSTALL_DIR/foreign-emacs.bak"
    echo "Found a non-sandboxed emacs binary at:"
    echo "  $existing"
    echo "It will be moved aside to:"
    echo "  $backup"
    echo ""
    read -rp "Proceed? [Y/n] " answer
    if [[ -n "$answer" && ! "$answer" =~ ^[Yy] ]]; then
        echo "Aborted by user. No changes made."
        exit 1
    fi
    mv "$existing" "$backup"
    echo "Moved $existing -> $backup"
    echo ""
fi

# ── Generate seccomp BPF ─────────────────────────────────────────────
echo "Generating seccomp BPF..."
deny_list="$INSTALL_DIR/emacs.seccomp.deny.list"
if [[ "$ALLOW_NESTED_SANDBOX" != "true" ]]; then
    # Hardened: append the mount family so nested bwrap is blocked too.
    echo "  Nested sandboxing disabled -- also blocking: $NESTED_BLOCK_SYSCALLS"
    deny_list="$INSTALL_DIR/emacs.seccomp.deny.effective.list"
    {
        cat "$INSTALL_DIR/emacs.seccomp.deny.list"
        echo ""
        echo "# --- appended by setup: nested sandboxing opted out ---"
        printf '%s\n' $NESTED_BLOCK_SYSCALLS
    } > "$deny_list"
fi
python3 "$INSTALL_DIR/gen-seccomp-bpf.py" "$deny_list" "$SECCOMP_BPF"
echo ""

# ── xdg-open shim (portal OpenURI for in-Emacs link clicks) ──────────
# Packages like browse-url, eww, helpful, etc. can shell out to
# xdg-open; routing that through the portal opens links on the host.
cat > "$INSTALL_DIR/bin/xdg-open" <<'WRAPPEREOF'
#!/bin/bash
for _u in "$@"; do
    gdbus call --session \
        --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop \
        --method org.freedesktop.portal.OpenURI.OpenURI \
        "" "$_u" "{}" >/dev/null 2>&1 || true
done
WRAPPEREOF
chmod +x "$INSTALL_DIR/bin/xdg-open"

# ── Write config ─────────────────────────────────────────────────────
write_emacs_sandbox_config

# ── Install wrapper at ~/.local/bin/emacs ────────────────────────────
# If something is already there and isn't our wrapper, refuse (we should
# have migrated above). Loop-detect just in case.
if [[ -e "$WRAPPER_PATH" || -L "$WRAPPER_PATH" ]]; then
    if ! emacs_is_our_wrapper "$WRAPPER_PATH"; then
        echo "Error: $WRAPPER_PATH exists and is not our wrapper (no marker)." >&2
        echo "This should not happen after migration; bailing out to avoid clobbering." >&2
        exit 1
    fi
fi
cp "$SCRIPT_DIR/emacs-sandbox.sh" "$WRAPPER_PATH"
chmod +x "$WRAPPER_PATH"

# ── Install override .desktop files ──────────────────────────────────
# The apt emacs-pgtk package ships /usr/share/applications/emacs.desktop
# (and friends) whose Exec= lines call /usr/bin/emacs directly. Clicking
# the Emacs icon in the GNOME activities / app grid would bypass the
# wrapper. Per the XDG basedir spec, user-level .desktop files at
# ~/.local/share/applications/ override the system ones with the same
# basename. We rewrite Exec= lines that invoke the GUI emacs binary to
# the wrapper; lines that use emacsclient are left unchanged (the client
# talks to the server socket and does not need the same bwrap view).
# Stamp a marker comment on line 1 so --uninstall can find them.
desktop_dir="$HOME/.local/share/applications"
mkdir -p "$desktop_dir"
shopt -s nullglob
installed_desktops=()
for src in /usr/share/applications/emacs*.desktop \
           /usr/share/applications/org.gnu.emacs*.desktop; do
    [[ -f "$src" ]] || continue
    name="$(basename "$src")"
    dst="$desktop_dir/$name"
    if [[ -e "$dst" ]] && ! emacs_desktop_is_ours "$dst"; then
        echo "Note: $dst exists without our marker; leaving it alone." >&2
        continue
    fi
    # python3 is already a hard prereq (seccomp BPF generation).
    python3 - "$src" "$WRAPPER_PATH" <<'PY' >"$dst.tmp"
import os
import re
import sys

src_path, wrapper = sys.argv[1], sys.argv[2]

# Match an "emacs" invocation token at a natural boundary: either
# right after the leading "Exec=" or after whitespace, optionally
# preceded by a path, with "emacs" as a complete identifier (next
# char is whitespace or end of input). The leading boundary is
# captured so it can be re-emitted in the replacement (otherwise the
# greedy \S*/ would also chew through "Exec=" when the path follows
# it directly). This rewrites:
#   Exec=emacs %F                        -> Exec=$wrapper %F
#   Exec=/usr/bin/emacs %F               -> Exec=$wrapper %F
#   Exec=/usr/local/bin/emacs --daemon   -> Exec=$wrapper --daemon
#   Exec=foo /usr/bin/emacs %F           -> Exec=foo $wrapper %F
#   Exec=env FOO=bar emacs %F            -> Exec=env FOO=bar $wrapper %F
#   Exec=sh -c "exec /usr/bin/emacs %F"  -> Exec=sh -c "exec $wrapper %F"
# Leaves untouched (next char is not a word boundary):
#   /usr/bin/emacsclient ...   ('c' follows 'emacs')
#   /usr/bin/emacs-gtk         ('-' follows)
#   /usr/bin/emacs.x86_64      ('.' follows)
#   /path/with/emacs/in/it     ('/' follows)
# The Exec= guard avoids rewriting stray mentions of "emacs" in
# Comment=, Name=, GenericName=, etc. The lambda replacement avoids
# re.sub's interpretation of backslash escapes in the replacement
# string (defensive against weird $HOME paths).
TOKEN_RE = re.compile(r"(^Exec=|\s)(?:\S*/)?emacs(?=\s|$)")

# Detect emacs-* / emacs.* variant binaries on Exec= lines that the
# rewriter intentionally leaves alone (because they are different
# binaries: emacs-gtk, emacs-nox, emacs-snapshot, emacs.x86_64, etc.).
# emacsclient is whitelisted -- it is intentionally not shadowed.
VARIANT_RE = re.compile(r"(?:^Exec=|\s)(?:\S*/)?(emacs[\w.\-]+)(?=\s|$)")
variants = set()

with open(src_path, encoding="utf-8", errors="replace") as f:
    for line in f:
        if line.startswith("Exec="):
            for m in VARIANT_RE.finditer(line):
                name = m.group(1)
                if name != "emacsclient":
                    variants.add(name)
            line = TOKEN_RE.sub(lambda m: m.group(1) + wrapper, line)
        sys.stdout.write(line)

for name in sorted(variants):
    print(
        f"  Note: {os.path.basename(src_path)} references {name!r}; "
        f"the wrapper does not shadow this binary, so launchers that "
        f"invoke it bypass the sandbox.",
        file=sys.stderr,
    )
PY
    {
        echo "$WRAPPER_MARKER"
        cat "$dst.tmp"
    } > "$dst"
    rm -f "$dst.tmp"
    installed_desktops+=("$dst")
done
shopt -u nullglob
if (( ${#installed_desktops[@]} > 0 )); then
    command -v update-desktop-database >/dev/null \
        && update-desktop-database "$desktop_dir" >/dev/null 2>&1 \
        || true
fi

# ── Done ─────────────────────────────────────────────────────────────
echo "Setup complete."
echo "  Workspace:    $WORKSPACE_DIR"
echo "  Emacs binary: $EMACS_BIN"
echo "  Seccomp BPF:  $SECCOMP_BPF ($(stat -c%s "$SECCOMP_BPF") bytes)"
if [[ "$ALLOW_NESTED_SANDBOX" == "true" ]]; then
    echo "  Nesting:      supported (mount family allowed)"
else
    echo "  Nesting:      disabled (mount family blocked)"
fi
echo "  Wrapper:      $WRAPPER_PATH"
echo "  Config:       $CONFIG_FILE"
if (( ${#installed_desktops[@]} > 0 )); then
    echo "  Desktop overrides:"
    for d in "${installed_desktops[@]}"; do
        echo "    $d"
    done
fi
echo ""
echo "Run 'emacs' from a workspace directory to launch."
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    echo "Note: $HOME/.local/bin is not in your PATH."
    echo "      Add it to your shell rc (e.g. echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc)."
fi
