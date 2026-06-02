# Emacs Linux Sandbox

Run [PGTK GNU Emacs](https://www.gnu.org/software/emacs/) inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox on Linux. Emacs and everything it executes (shells, `M-x compile`, LSP servers, formatters, package downloads, ...) are confined to an explicit allowlist of paths -- your workspace, `~/.emacs.d`, fonts, and a small set of read-only tool installs (cargo, rustup, nvm, pyenv, pnpm, etc.). The rest of your filesystem is invisible.

The profile follows the same bubblewrap pattern as typical CLI sandboxes (tmpfs `$HOME`, explicit binds, filtered D-Bus, seccomp), adapted for a long-running GUI process on Wayland. The system `/usr/bin/emacs` is unchanged; a wrapper at `~/.local/bin/emacs` shadows it on PATH, and `.desktop` launchers under `~/.local/share/applications/` are rewritten to call the wrapper so the GNOME app grid / activities icon also goes through the sandbox.

> **Disclaimer:** Personal project, not affiliated with or endorsed by the GNU project or the bubblewrap authors. The sandbox is best-effort -- Linux user-namespace isolation is not a security boundary against a determined attacker, and escape paths exist (in particular through unrestricted network egress). Review [`emacs-sandbox.sh`](emacs-sandbox.sh) and [`emacs.seccomp.deny.list`](emacs.seccomp.deny.list) before use. Provided as-is, no warranty (see [LICENSE](LICENSE)).

## What the sandbox enforces

- **Filesystem isolation** -- `$HOME` is a tmpfs by default; only explicitly bound paths are visible (workspace rw, `~/.emacs.d` rw, shell rc / git config / fonts / tool installs ro). `~/.config`, `~/.cache`, and `~/.local` are sandbox-private overlays backed by `~/.local/share/emacs-sandbox/`, so subprocess XDG writes persist on disk without touching the host's real ones.
- **User namespace** -- no SUID binary involved, no root inside the sandbox, `NoNewPrivileges` set.
- **All Linux capabilities dropped.**
- **Seccomp filter** -- generated at setup time from [`emacs.seccomp.deny.list`](emacs.seccomp.deny.list); blocks ~40 syscalls historically tied to kernel exploits (io_uring, bpf, userfaultfd, kexec, ptrace, etc.). The `mount` family is left allowed so a nested bubblewrap sandbox can run (see [Nested sandboxing](#nested-sandboxing)).
- **PID, UTS, IPC, cgroup namespaces** unshared -- no view of host processes.
- **Filtered session D-Bus** via `xdg-dbus-proxy` -- only `org.freedesktop.portal.Desktop`, `org.freedesktop.portal.OpenURI`, and `org.freedesktop.Notifications`.
- **Wayland-only display** -- `GDK_BACKEND=wayland`, `DISPLAY` unset, only the `wayland-0` socket bound. No Xwayland fallback path is reachable.
- **Ephemeral `/dev`, `/tmp`, `/run`** -- standard bwrap minimal `/dev`, fresh tmpfs for `/tmp` and `/run`.

Emacs **can** use the network, your terminal, your git config (ro), and any read-only tool installs you opt in to. It **cannot** see your home directory, other projects, SSH keys, browser data, GPG keyring, `~/.authinfo`, or host processes.

## Prereqs: PGTK Emacs + Wayland

This sandbox is built around the **PGTK** (pure-GTK) Emacs build, which talks to the Wayland compositor directly. The Xwayland fallback path is intentionally cut off, so:

- **Your distro's PGTK Emacs package.** On Ubuntu/Debian:

  ```bash
  sudo apt install emacs-pgtk
  ```

  Setup validates the build with `emacs --batch --eval "(featurep 'pgtk)"` and refuses to proceed if the predicate is false. Point at a different binary with `EMACS_BIN=/path/to/pgtk-emacs ./emacs-sandbox-setup.sh` if your PGTK build lives elsewhere (e.g. a source build).

- **A Wayland session.** Setup checks `$XDG_SESSION_TYPE` and warns (not fatal) if it isn't `wayland`. The launcher sets `GDK_BACKEND=wayland` and unsets `DISPLAY`, so on an X11-only session the sandboxed Emacs will fail to open a window.

- **An init file under `~/.emacs.d/init.el` (or the legacy `~/.emacs`).** Both are supported: `~/.emacs.d` is bound rw, and `~/.emacs` is bound rw too when the file exists.

Other prerequisites:

- Linux with user namespaces enabled (default on all modern distros)
- `bubblewrap` (bwrap)
- `xdg-dbus-proxy` (filtered session bus)
- `gdbus` (from GLib, for the xdg-open portal shim)
- `python3` + libseccomp Python bindings (BPF generation at setup time)

```bash
sudo apt install bubblewrap xdg-dbus-proxy libglib2.0-bin python3 python3-seccomp     # Debian/Ubuntu
sudo dnf install bubblewrap xdg-dbus-proxy glib2 python3 python3-libseccomp           # Fedora
sudo pacman -S bubblewrap xdg-desktop-portal glib2 python python-libseccomp           # Arch
```

## Setup

Run setup once:

```bash
./emacs-sandbox-setup.sh
```

This prompts for a workspace directory, validates that `/usr/bin/emacs` is a PGTK build, generates the seccomp BPF blob, installs the xdg-open shim, installs override `.desktop` files under `~/.local/share/applications/`, and writes the wrapper to `~/.local/bin/emacs`.

Re-run setup after pulling repo changes (to update the wrapper and regenerate the BPF) or after editing [`emacs.seccomp.deny.list`](emacs.seccomp.deny.list).

Override defaults:

```bash
WORKSPACE_DIR=$HOME/repos ./emacs-sandbox-setup.sh
EMACS_BIN=/opt/emacs-trunk/bin/emacs ./emacs-sandbox-setup.sh
```

Setup flags:

- `--uninstall` -- remove `~/.local/opt/emacs-sandbox/`, the wrapper at `~/.local/bin/emacs` (only if it is ours), and any `~/.local/share/applications/emacs*.desktop` / `org.gnu.emacs*.desktop` carrying our marker. Preserves `~/.emacs.d` and `~/.emacs`.

### Migrating an existing `~/.local/bin/emacs`

If you already have a hand-rolled emacs binary at `~/.local/bin/emacs` (without our marker), setup will offer to move it aside to `~/.local/opt/emacs-sandbox/foreign-emacs.bak` before installing the wrapper.

## Usage

From any subdirectory of your workspace:

```bash
cd ~/proj/some-repo && emacs
emacs path/to/file.el
emacsclient -c    # opens a frame against a sandboxed server, if you start one
```

The wrapper at `~/.local/bin/emacs` is the only `emacs` on your PATH (on Ubuntu, `~/.local/bin` precedes `/usr/bin`); it always invokes the sandbox. Clicking the Emacs icon in the GNOME activities / app grid also routes through the wrapper, because the `.desktop` overrides under `~/.local/share/applications/` take precedence over the system ones at `/usr/share/applications/`.

The launcher propagates `$PWD` into the sandbox when it sits under the workspace or `~/.emacs.d`. If `$PWD` isn't bound and you launched from a terminal, the wrapper bails with a clear error so the surprise of "Emacs opened, but not where I expected" doesn't happen silently -- `cd` somewhere bound and re-launch. Desktop launchers (no terminal on stderr) always succeed and start in the workspace root, since the icon click has no meaningful cwd anyway. For a one-off custom start dir, pass `EMACS_SANDBOX_EXTRA_ARGS="--chdir /some/bound/path"`.

### Narrowing the writable scope per invocation

`WORKSPACE_DIR` can be narrowed (never widened) at invocation time via `EMACS_SANDBOX_WORKSPACE`, which must be a subdirectory of `WORKSPACE_DIR` or equal to it:

```bash
EMACS_SANDBOX_WORKSPACE=~/proj/some-repo emacs
```

This way an Emacs session opened to hack on one repo can't accidentally write into siblings under `~/proj`.

## Tools

These directories are exposed **read-only** if they exist: `~/.cargo`, `~/.rustup`, `~/.nvm`, `~/.pyenv`, `~/go`, `~/.local/share/pnpm`, `~/.local/bin`. Compilers, interpreters, language servers, and CLI tools installed there work inside the sandbox (e.g. `M-x compile` running `cargo build`, `eglot` spawning `rust-analyzer`), but installing or updating them (`nvm install`, `rustup update`, `pip install --user`, etc.) must happen outside the sandbox.

Package-manager **caches** are carved out as **read-write** within those trees and shared with the host: `~/.cargo/registry`, `~/.npm/_cacache`, `~/.local/share/pnpm/store`, `~/.cache/pip`, `~/go/pkg/mod`, `~/.cache/go-build`. This lets `cargo build`, `npm install`, `pnpm install`, `pip install`, and `go build` work from inside `M-x compile`. Sharing is safe because each tool verifies cache content against a lockfile (cargo SHA-256 vs `Cargo.lock`, npm SRI vs `package-lock.json`, pnpm content-addressed store, pip `--require-hashes`, Go module SHA-256 vs `go.sum`), so a sandboxed process cannot substitute forged cache entries for host or other-project builds.

Shell rc files are exposed read-only too: `~/.bashrc`, `~/.profile`, `~/.bash_profile`, `~/.zshrc`, `~/.zshenv`, `~/.inputrc`. Subshells spawned from `M-x shell`, `vterm`, `ansi-term` feel familiar.

Fonts are bound read-only from `~/.local/share/fonts` and `~/.config/fontconfig` (if they exist), so user-installed fonts and any fontconfig overrides apply inside the sandbox.

### XDG state: `~/.config`, `~/.cache`, `~/.local`

Inside the sandbox, `~/.config`, `~/.cache`, and `~/.local` are bound from `~/.local/share/emacs-sandbox/{config,cache,local}` on the host -- the host's real XDG dirs are invisible. Subprocess writes (LSP state, language-tool caches, app data under `~/.local/share`, state under `~/.local/state`, dotfile-style configs) persist across sessions on disk but never reach the host's real ones. `rm -rf ~/.local/share/emacs-sandbox/{config,cache,local}` to reset. Specific host paths are re-exposed read-only on top of the overlay where Emacs needs them: `~/.config/fontconfig` (fonts), `~/.config/dconf` (GSettings / GTK theming), `~/.config/gtk-3.0`, `~/.config/gtk-4.0`, `~/.local/bin` (user CLI tools), `~/.local/share/pnpm` (toolchain). If a package needs more of the host's XDG tree visible inside, add it via the extension hooks below.

### Deliberate omissions: SSH, credentials, GPG

By default the sandbox does **not** bind:

- `~/.ssh` (so `magit-push` over `git@github.com:` will fail; use HTTPS, or run pushes from a host shell)
- `$SSH_AUTH_SOCK` (no ssh-agent reachable)
- `~/.authinfo`, `~/.authinfo.gpg` (no plaintext or GPG-encrypted credentials)
- `$XDG_RUNTIME_DIR/gnupg` (no `gpg` agent reachable; signing commits over GPG-agent will fail)

These are intentional. If you want them re-added (e.g. you do want a sandboxed Magit to push over SSH), use the extension hooks below.

## Extending the sandbox

If a package needs filesystem paths or sockets beyond the workspace + `~/.emacs.d`, there are two hooks to splice extra bwrap arguments in. Each entry widens the sandbox -- use sparingly.

**Persistent: `~/.local/opt/emacs-sandbox/emacs-sandbox.local`** -- plain text, one bwrap directive per line. `#` starts a comment, blank lines are ignored, and `${HOME}` / `${INSTALL_DIR}` / other env vars are expanded:

```
# Re-bind SSH and ssh-agent for magit push/pull over git@... :
--ro-bind     ${HOME}/.ssh            ${HOME}/.ssh
--ro-bind-try ${SSH_AUTH_SOCK}        ${SSH_AUTH_SOCK}

# GPG-encrypted authinfo + gpg-agent socket (for commit signing, smtpmail, ...):
--ro-bind     ${HOME}/.authinfo.gpg   ${HOME}/.authinfo.gpg
--ro-bind     ${XDG_RUNTIME_DIR}/gnupg ${XDG_RUNTIME_DIR}/gnupg

# Extra tool install + state dirs:
--ro-bind /opt/foo /opt/foo
--bind    ${HOME}/.config/foo ${HOME}/.config/foo
```

The file lives alongside the installed launcher (outside the sandbox's writable scope), so it can't be tampered with from inside Emacs.

> **Footgun: `--setenv` is last-wins.** bwrap applies repeated `--setenv NAME …` left-to-right, with the last one overwriting earlier ones. Two hook blocks that each do `--setenv PATH "X:${PATH}"` and `--setenv PATH "Y:${PATH}"` won't compose -- only `Y` survives, and `X` (plus the script's own `INSTALL_DIR/bin:$HOME/.local/bin` prefix from its own `--setenv PATH`) is silently dropped. Same applies to any other env var. Recommended pattern: at most one `--setenv PATH` per file, with the full prefix chain spelled out, e.g. `"${HOME}/.foundry/bin:${HOME}/.local/opt/claude/bin:${INSTALL_DIR}/bin:${HOME}/.local/bin:${PATH}"`. For single-binary tools, prefer shadowing the binary at a path that's already in PATH (e.g. `--ro-bind /resolved/binary ${HOME}/.local/bin/<tool>`) instead of growing PATH.

**Per-invocation: `$EMACS_SANDBOX_EXTRA_ARGS`** -- space-separated bwrap args for a single launch:

```bash
EMACS_SANDBOX_EXTRA_ARGS="--ro-bind /opt/something /opt/something" emacs
```

## Nested sandboxing

A bubblewrap sandbox launched from a terminal inside Emacs (for example a
sandboxed CLI tool that confines its own subprocesses) needs to build its own
mount namespace. This sandbox supports that: the inner bwrap needs `mount`,
`umount2`, and `pivot_root`, which the seccomp filter leaves allowed (see
[`emacs.seccomp.deny.list`](emacs.seccomp.deny.list)). User-namespace nesting
works inside the sandbox already.

**Trade-off.** Allowing the mount family widens kernel attack surface (it has a
CVE history), which is why firejail-style filters block it. It does *not* weaken
this sandbox's filesystem boundary: the outer read-only binds are created in a
less-privileged user namespace, so their read-only flags are locked and the
nested sandbox cannot clear them.

**Opting out.** Nested support is on by default. To restore the hardened filter
that blocks the mount family, run setup with `--no-nested-sandbox` (or
`EMACS_SANDBOX_ALLOW_NESTED=0 ./emacs-sandbox-setup.sh`). The choice is recorded
as `ALLOW_NESTED_SANDBOX` in the config (`~/.local/opt/emacs-sandbox/.emacs-sandbox.env`)
and reused on subsequent re-runs; setup prompts for it on a fresh install.

## Customising the seccomp filter

The deny-list lives in [`emacs.seccomp.deny.list`](emacs.seccomp.deny.list). Edit it, re-run `./emacs-sandbox-setup.sh`, and the new BPF is generated by [`gen-seccomp-bpf.py`](gen-seccomp-bpf.py) at `~/.local/opt/emacs-sandbox/emacs.seccomp.bpf`. If Emacs (or native-comp, or some package) hits a denied syscall and fails with `Operation not permitted`, remove that syscall from the list and re-run setup.

## Troubleshooting

**`emacs` not found** -- ensure `~/.local/bin` is in your PATH. Setup prints a notice if it's not.

**Sandbox refuses to start** -- run `emacs` from a terminal so you can see the error. Common causes:
- `bwrap` not installed.
- User namespaces disabled on your kernel. Check `sysctl kernel.unprivileged_userns_clone` -- should be `1`. On Ubuntu 24.04 see the AppArmor remediation that setup prints.
- Seccomp BPF file missing or wrong architecture -- re-run setup.

**Empty Emacs frame / no UI** -- you're probably not on a Wayland session, or your PGTK build can't reach the compositor. Verify `echo $XDG_SESSION_TYPE` reports `wayland` on the host. The sandbox unsets `DISPLAY` deliberately to deny Xwayland fallback; if you really need Xwayland, bind the X11 socket and `Xauthority` through the local profile (and switch to a non-PGTK build).

**Magit push fails over SSH** -- by design (see "Deliberate omissions"). Either switch the remote to HTTPS, push from a host shell, or add the SSH binds via the local profile.

**Package install / `M-x list-packages` hangs or fails** -- the sandbox does allow network egress, so this is usually a DNS or proxy issue, not the sandbox. Verify resolver state binds picked up (`cat /etc/resolv.conf` inside the sandbox via `M-x shell`).

**xdg-open / `browse-url` does nothing** -- the xdg-open shim needs `xdg-dbus-proxy` running and `xdg-desktop-portal` on the host. Without these, URLs from `helpful` / `eww` / `M-x browse-url-at-point` are silently dropped. Setup checks `xdg-dbus-proxy` is installed but not that the portal is reachable.

## License

MIT -- see [LICENSE](LICENSE).
