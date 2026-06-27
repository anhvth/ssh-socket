#!/usr/bin/env sh
set -eu

repo_raw="${VSCODE_SSH_REPO_RAW:-https://raw.githubusercontent.com/anhvth/ssh-tmux-copy/main}"
install_dir="${VSCODE_SSH_INSTALL_DIR:-${HOME}/.local/bin}"
install_path="${install_dir}/vsc"
tmp="${TMPDIR:-/tmp}/vsc.$$"

mkdir -p "$install_dir"

cleanup() {
    rm -f "$tmp"
}
trap cleanup EXIT INT TERM

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${repo_raw}/vscode-ssh.sh" -o "$tmp"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "${repo_raw}/vscode-ssh.sh"
else
    echo "install-vsc: curl or wget is required" >&2
    exit 1
fi

chmod +x "$tmp"
mv "$tmp" "$install_path"
trap - EXIT INT TERM

echo "install-vsc: installed ${install_path}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "install-vsc: warning: python3 is required when running vsc on a remote machine" >&2
fi

case ":${PATH:-}:" in
    *":${install_dir}:"*) ;;
    *)
        echo "install-vsc: add this to your shell rc if needed:" >&2
        echo "  export PATH=\"${install_dir}:\$PATH\"" >&2
        ;;
esac
