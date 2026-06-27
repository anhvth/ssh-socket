#!/usr/bin/env sh
set -eu

repo_raw="${SSH_BRIDGE_REPO_RAW:-https://raw.githubusercontent.com/anhvth/ssh-socket/refs/heads/main}"
install_dir="${SSH_BRIDGE_INSTALL_DIR:-${VSCODE_SSH_INSTALL_DIR:-${HOME}/.local/bin}}"
dotfiles_bin="${HOME}/dotfiles/mybins"
tmp="${TMPDIR:-/tmp}/ssh-bridge.$$"

mkdir -p "$install_dir"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT INT TERM

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${repo_raw}/ssh-bridge.sh" -o "$tmp"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "${repo_raw}/ssh-bridge.sh"
else
    echo "install-vsc: curl or wget is required" >&2
    exit 1
fi

chmod +x "$tmp"
for old_name in ssh-bridge vsc open open-remote copy pbcopy vsc-bridge vsc-ssh-local-command; do
    rm -f "${install_dir}/${old_name}"
    if [ -d "$dotfiles_bin" ]; then
        rm -f "${dotfiles_bin}/${old_name}"
    fi
done
cp "$tmp" "${install_dir}/ss-bridge"
chmod +x "${install_dir}/ss-bridge"
for name in ss-code ss-open ss-open-remote ss-copy ss-pbcopy ss-health ss-setup; do
    cp "$tmp" "${install_dir}/${name}"
    chmod +x "${install_dir}/${name}"
done
trap - EXIT INT TERM
rm -f "$tmp"

if command -v tmux >/dev/null 2>&1; then
    copy_cmd="${install_dir}/ss-copy"
    tmux bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -n DoubleClick1Pane select-pane \; copy-mode -M \; send-keys -X select-word \; send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -n TripleClick1Pane select-pane \; copy-mode -M \; send-keys -X select-line \; send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode-vi DoubleClick1Pane select-pane \; send-keys -X select-word \; send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
    tmux bind-key -T copy-mode-vi TripleClick1Pane select-pane \; send-keys -X select-line \; send-keys -X copy-pipe-and-cancel "$copy_cmd" 2>/dev/null || true
fi

echo "install-vsc: installed ss-bridge, ss-code, ss-open, ss-open-remote, ss-copy, ss-pbcopy, ss-health, ss-setup into ${install_dir}"
if ! command -v python3 >/dev/null 2>&1; then
    echo "install-vsc: warning: python3 is required when running remote bridge clients" >&2
fi
case ":${PATH:-}:" in
    *":${install_dir}:"*) ;;
    *)
        echo "install-vsc: add this to your shell rc if needed:" >&2
        echo "  export PATH=\"${install_dir}:\$PATH\"" >&2
        ;;
esac
