#!/usr/bin/env bash
set -euo pipefail

VSCODE_SSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BASE_DIR="${VSCODE_SSH_LOCAL_DIR:-$HOME/.cache/vscode-ssh}"
LOCAL_SOCKET="${LOCAL_BASE_DIR}/bridge.sock"
LOCAL_PID="${LOCAL_BASE_DIR}/bridge.pid"
LOCAL_LOG="${LOCAL_BASE_DIR}/bridge.log"
REMOTE_PORT="${VSCODE_SSH_REMOTE_PORT:-47371}"

usage() {
    cat <<'EOF'
Usage:
  vsc [path] [--vvv]
  vscode-ssh.sh vsc [path] [--vvv]
  vscode-ssh.sh bridge {start|serve|stop|status} [--quiet]
  vscode-ssh.sh local-command <ssh-host> [ssh-user]

Open remote paths in local VS Code through the active SSH path.
Remote runtime state lives in /tmp/vscode-ssh/$USER/$HOSTNAME.
EOF
}

if [[ "$(basename "$0")" == "vsc" ]]; then
    cmd="vsc"
else
    cmd="${1:-help}"
    [[ $# -gt 0 ]] && shift
fi

choose_code_cmd() {
    if [[ -x /usr/local/bin/code ]]; then
        echo /usr/local/bin/code
        return 0
    fi
    if command -v code >/dev/null 2>&1; then
        command -v code
        return 0
    fi
    if command -v code-insiders >/dev/null 2>&1; then
        command -v code-insiders
        return 0
    fi
    return 1
}

resolve_path() {
    local input="$1"
    local resolved=""
    if command -v realpath >/dev/null 2>&1; then
        resolved="$(realpath -m "$input" 2>/dev/null || realpath "$input" 2>/dev/null || true)"
    fi
    if [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
    elif [[ "$input" == /* ]]; then
        printf '%s\n' "$input"
    else
        printf '%s/%s\n' "$(pwd -P)" "$input"
    fi
}

remote_state_dir() {
    local host
    host="$(hostname 2>/dev/null || printf unknown)"
    printf '%s\n' "${VSC_REMOTE_STATE_DIR:-/tmp/vscode-ssh/${USER:-user}/${host}}"
}

bridge_python() {
    python3 - "$@" <<'PY'
import argparse
import json
import os
import shlex
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

base_dir = Path(os.environ["VSCODE_SSH_LOCAL_DIR"])
socket_path = Path(os.environ["VSCODE_SSH_LOCAL_SOCKET"])
pid_path = Path(os.environ["VSCODE_SSH_LOCAL_PID"])
log_path = Path(os.environ["VSCODE_SSH_LOCAL_LOG"])

def which(name):
    for part in os.environ.get("PATH", "").split(os.pathsep):
        if not part:
            continue
        candidate = Path(part) / name
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None

def choose_code_cmd():
    preferred = Path("/usr/local/bin/code")
    if preferred.exists() and os.access(preferred, os.X_OK):
        return str(preferred)
    return which("code") or which("code-insiders")

def parse_ssh_config_aliases(config_path):
    aliases = {}
    current_hosts = []
    try:
        lines = Path(config_path).read_text().splitlines()
    except OSError:
        return aliases
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if not parts:
            continue
        key = parts[0].lower()
        if key == "host":
            current_hosts = [p for p in parts[1:] if "*" not in p and "?" not in p]
        elif key == "hostname" and current_hosts and len(parts) >= 2:
            aliases.setdefault(parts[1], current_hosts[0])
    return aliases

def resolve_remote_target(payload):
    explicit = (payload.get("ssh_to_me") or "").strip()
    if explicit:
        return explicit.split(None, 1)[1].strip() if explicit.startswith("ssh ") else explicit
    host = (payload.get("host") or "").strip()
    if not host:
        return ""
    return parse_ssh_config_aliases(Path.home() / ".ssh" / "config").get(host, host)

def handle_payload(payload):
    if payload.get("ping"):
        return {"status": "ok", "message": "pong"}
    code_cmd = choose_code_cmd()
    if not code_cmd:
        return {"status": "error", "message": "local machine does not have code or code-insiders in PATH"}
    path = (payload.get("path") or "").strip()
    remote_target = resolve_remote_target(payload)
    if not path:
        return {"status": "error", "message": "request did not include a path"}
    if not remote_target:
        return {"status": "error", "message": "request did not include a remote host"}
    cmd = [code_cmd, "--remote", f"ssh-remote+{remote_target}", path]
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return {
        "status": "ok",
        "code": code_cmd,
        "remote": remote_target,
        "path": path,
        "command": " ".join(shlex.quote(part) for part in cmd),
    }

def serve():
    base_dir.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        socket_path.unlink()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    socket_path.chmod(0o600)
    server.listen(16)
    pid_path.write_text(str(os.getpid()))

    def cleanup(*_):
        try:
            server.close()
        finally:
            for path in (socket_path, pid_path):
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    while True:
        conn, _ = server.accept()
        with conn:
            data = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break
            try:
                response = handle_payload(json.loads(data.decode("utf-8").strip()))
            except Exception as exc:
                response = {"status": "error", "message": str(exc)}
            try:
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
            except BrokenPipeError:
                pass

def socket_responds():
    if not socket_path.exists():
        return False
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(0.5)
        client.connect(str(socket_path))
        client.sendall(b'{"ping":true}\n')
        data = client.recv(65536)
        client.close()
        return b'"status": "ok"' in data or b'"status":"ok"' in data
    except OSError:
        return False

def start(quiet=False):
    base_dir.mkdir(parents=True, exist_ok=True)
    if socket_responds():
        if not quiet:
            print(f"vscode-ssh bridge: running at {socket_path}")
        return 0
    if socket_path.exists():
        socket_path.unlink()
    log = log_path.open("ab")
    subprocess.Popen(
        ["/bin/bash", os.environ["VSCODE_SSH_SCRIPT"], "bridge", "serve"],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    for _ in range(20):
        if socket_responds():
            if not quiet:
                print(f"vscode-ssh bridge: started at {socket_path}")
            return 0
        time.sleep(0.05)
    print(f"vscode-ssh bridge: failed to start; see {log_path}", file=sys.stderr)
    return 1

def stop():
    try:
        pid = int(pid_path.read_text().strip())
    except (OSError, ValueError):
        pid = None
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for path in (socket_path, pid_path):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    print("vscode-ssh bridge: stopped")
    return 0

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["start", "serve", "stop", "status"])
parser.add_argument("--quiet", action="store_true")
args = parser.parse_args()

if args.action == "serve":
    serve()
elif args.action == "start":
    raise SystemExit(start(args.quiet))
elif args.action == "stop":
    raise SystemExit(stop())
elif args.action == "status":
    if socket_responds():
        print(f"vscode-ssh bridge: running at {socket_path}")
        raise SystemExit(0)
    print("vscode-ssh bridge: stopped")
    raise SystemExit(1)
PY
}

bridge_cmd() {
    local action="${1:-status}"
    [[ $# -gt 0 ]] && shift
    export VSCODE_SSH_LOCAL_DIR="$LOCAL_BASE_DIR"
    export VSCODE_SSH_LOCAL_SOCKET="$LOCAL_SOCKET"
    export VSCODE_SSH_LOCAL_PID="$LOCAL_PID"
    export VSCODE_SSH_LOCAL_LOG="$LOCAL_LOG"
    export VSCODE_SSH_SCRIPT="${BASH_SOURCE[0]}"
    bridge_python "$action" "$@"
}

print_remote_bridge_help() {
    local alias_hint="${1:-}" host="${2:-unknown}" state_dir="${3:-}" socket="${4:-}" bridge_tcp="${5:-}"
    local reconnect_target="${alias_hint:-<ssh-config-host>}"

    cat >&2 <<EOF
Problem: SSH host '${reconnect_target}' is missing the local VS Code bridge for this SSH session.
Cause: remote 'vsc' is installed, but your Mac did not create the SSH bridge/tunnel when you connected.
Note: use the Host name from your LOCAL ~/.ssh/config, not the remote machine hostname '${host}'.

Solution: on your LOCAL Mac, add these lines to the matching Host block in ~/.ssh/config:

Host ${reconnect_target}
    PermitLocalCommand yes
    LocalCommand /Users/anhvth/dotfiles/3rd/ssh_tmux_copy/vscode-ssh.sh local-command %n %r
    SetEnv _SSH_TO_ME=%n

Then reconnect from your Mac with: ssh ${reconnect_target}

Note: curl | sh only installs remote 'vsc'; it does not configure your Mac SSH bridge.
Remote install command: curl -fsSL https://raw.githubusercontent.com/anhvth/ssh-tmux-copy/main/install-vsc.sh | sh

Debug: ssh_config_host=${reconnect_target} remote_machine_hostname=${host} state_dir=${state_dir} socket=${socket} tcp=${bridge_tcp:-<unset>}
EOF
}

vsc_cmd() {
    local debug=0 target_raw="" arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; return 0 ;;
            --vvv) debug=1 ;;
            *)
                if [[ -z "$target_raw" ]]; then
                    target_raw="$arg"
                else
                    echo "vsc: unexpected argument: $arg" >&2
                    return 2
                fi
                ;;
        esac
    done

    target_raw="${target_raw:-.}"
    local target
    target="$(resolve_path "$target_raw")"

    if [[ -z "${SSH_CONNECTION:-}" && -z "${SSH_TTY:-}" && -z "${SSH_CLIENT:-}" ]]; then
        local code_cmd
        code_cmd="$(choose_code_cmd)" || {
            echo "vsc: neither 'code' nor 'code-insiders' is available." >&2
            return 127
        }
        (( debug )) && printf 'vsc debug: local path=%s code=%s\n' "$target" "$code_cmd" >&2
        exec "$code_cmd" "$target"
    fi

    local state_dir socket bridge_tcp host ssh_to_me
    state_dir="$(remote_state_dir)"
    socket="${VSC_BRIDGE_SOCKET_REMOTE:-/tmp/vsc-open-${USER}.sock}"
    [[ -z "${VSC_BRIDGE_SOCKET_REMOTE:-}" && -r "$state_dir/socket" ]] && socket="$(sed -n '1p' "$state_dir/socket" 2>/dev/null || printf '%s' "$socket")"
    bridge_tcp="${VSC_BRIDGE_TCP_REMOTE:-}"
    [[ -z "$bridge_tcp" && -r "$state_dir/tcp" ]] && bridge_tcp="$(sed -n '1p' "$state_dir/tcp" 2>/dev/null || true)"
    host="$(hostname 2>/dev/null || printf unknown)"
    ssh_to_me="${_SSH_TO_ME:-${VSC_REMOTE_HOST:-}}"
    [[ -z "$ssh_to_me" && -r "$state_dir/ssh_to_me" ]] && ssh_to_me="$(sed -n '1p' "$state_dir/ssh_to_me" 2>/dev/null || true)"

    (( debug )) && {
        printf 'vsc debug: remote path=%s\n' "$target" >&2
        printf 'vsc debug: state_dir=%s\n' "$state_dir" >&2
        printf 'vsc debug: socket=%s\n' "$socket" >&2
        printf 'vsc debug: tcp=%s\n' "${bridge_tcp:-<unset>}" >&2
        printf 'vsc debug: host=%s\n' "$host" >&2
        printf 'vsc debug: ssh_to_me=%s\n' "${ssh_to_me:-<unset>}" >&2
    }

    if [[ -z "$bridge_tcp" && ! -S "$socket" ]]; then
        print_remote_bridge_help "$ssh_to_me" "$host" "$state_dir" "$socket" "$bridge_tcp"
        return 1
    fi

    local response status message
    response="$(
        VSC_PATH="$target" \
        VSC_HOST="$host" \
        VSC_SSH_TO_ME="$ssh_to_me" \
        VSC_USER="${USER:-}" \
        VSC_SOCKET="$socket" \
        VSC_TCP="$bridge_tcp" \
        python3 - <<'PY'
import json
import os
import socket
import sys

payload = {
    "path": os.environ["VSC_PATH"],
    "host": os.environ["VSC_HOST"],
    "ssh_to_me": os.environ.get("VSC_SSH_TO_ME") or "",
    "user": os.environ.get("VSC_USER") or "",
}

sock_path = os.environ["VSC_SOCKET"]
tcp_target = os.environ.get("VSC_TCP") or ""
client = None
try:
    if tcp_target:
        host, port = tcp_target.rsplit(":", 1)
        client = socket.create_connection((host, int(port)), timeout=2)
    else:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(sock_path)
    client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
    client.shutdown(socket.SHUT_WR)
    data = client.recv(65536).decode("utf-8", "replace")
except OSError as exc:
    print(json.dumps({
        "status": "error",
        "message": f"local VS Code bridge socket is not accepting connections ({exc.strerror or exc})",
    }))
    raise SystemExit(0)
finally:
    if client is not None:
        try:
            client.close()
        except Exception:
            pass

sys.stdout.write(data)
PY
    )"
    (( debug )) && printf 'vsc debug: bridge response=%s\n' "$response" >&2
    status="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","error"))' 2>/dev/null || printf error)"
    if [[ "$status" != "ok" ]]; then
        message="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message","bridge request failed"))' 2>/dev/null || printf 'bridge request failed')"
        echo "vsc: $message" >&2
        if [[ "$message" == *"bridge socket"* || "$message" == *"accepting connections"* || "$message" == *"Connection refused"* ]]; then
            print_remote_bridge_help "$ssh_to_me" "$host" "$state_dir" "$socket" "$bridge_tcp"
        fi
        return 1
    fi
}

local_command_cmd() {
    local ssh_host="${1:-}" ssh_user="${2:-}"
    [[ -n "$ssh_host" ]] || return 0

    bridge_cmd start --quiet || true

    local ssh_target="$ssh_host"
    [[ -n "$ssh_user" ]] && ssh_target="${ssh_user}@${ssh_host}"
    mkdir -p "$LOCAL_BASE_DIR"

    {
        cat <<'REMOTE_SETUP_PREFIX'
set -eu
ssh_to_me="$1"
remote_tcp_port="$2"
install_dir="$HOME/.local/bin"
dotfiles_bin="$HOME/dotfiles/mybins"
remote_host="$(hostname 2>/dev/null || printf unknown)"
state_dir="/tmp/vscode-ssh/${USER:-user}/${remote_host}"
mkdir -p "$install_dir" "$state_dir"
printf "127.0.0.1:%s\n" "$remote_tcp_port" > "$state_dir/tcp"
tmp="${TMPDIR:-/tmp}/vsc.$$"
base64 -d > "$tmp" <<'VSC_CLIENT_B64'
REMOTE_SETUP_PREFIX
        base64 < "${BASH_SOURCE[0]}"
        cat <<'REMOTE_SETUP_SUFFIX'
VSC_CLIENT_B64
chmod +x "$tmp"
cp "$tmp" "$install_dir/vsc"
rm -f "$tmp"
if [ -d "$HOME/dotfiles" ]; then
    mkdir -p "$dotfiles_bin"
    cp "$install_dir/vsc" "$dotfiles_bin/vsc"
    chmod +x "$dotfiles_bin/vsc"
fi
printf '%s\n' "$ssh_to_me" > "$state_dir/ssh_to_me"
if ! command -v python3 >/dev/null 2>&1; then
    echo "vscode-ssh: installed vsc, but python3 is required for socket requests" >&2
fi
REMOTE_SETUP_SUFFIX
    } | ssh \
        -o PermitLocalCommand=no \
        -o LocalCommand=true \
        -o ClearAllForwardings=yes \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o BatchMode=yes \
        "$ssh_target" \
        sh -s -- "$ssh_host" "$REMOTE_PORT" >>"$LOCAL_LOG" 2>&1 || true

    if ssh \
        -o PermitLocalCommand=no \
        -o LocalCommand=true \
        -o ClearAllForwardings=yes \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o BatchMode=yes \
        "$ssh_target" \
        python3 - "$REMOTE_PORT" >>"$LOCAL_LOG" 2>&1 <<'PY'
import json
import socket
import sys

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=1) as client:
    client.sendall(b'{"ping": true}\n')
    client.shutdown(socket.SHUT_WR)
    data = client.recv(65536).decode("utf-8", "replace")
response = json.loads(data)
raise SystemExit(0 if response.get("status") == "ok" else 1)
PY
    then
        return 0
    fi

    local existing_tunnel_pids
    existing_tunnel_pids="$(
        ps -axo pid,command |
            awk -v port="$REMOTE_PORT" -v target="$ssh_target" '
                $0 ~ "ssh .*127\\.0\\.0\\.1:" port ":" && $0 ~ target && $0 !~ /awk/ { print $1 }
            '
    )"
    if [[ -n "$existing_tunnel_pids" ]]; then
        kill $existing_tunnel_pids 2>/dev/null || true
        sleep 0.2
    fi

    ssh \
        -fN \
        -o PermitLocalCommand=no \
        -o LocalCommand=true \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o ExitOnForwardFailure=yes \
        -o BatchMode=yes \
        -R "127.0.0.1:${REMOTE_PORT}:${LOCAL_SOCKET}" \
        "$ssh_target" >>"$LOCAL_LOG" 2>&1 || true
}

case "$cmd" in
    vsc) vsc_cmd "$@" ;;
    bridge) bridge_cmd "$@" ;;
    local-command) local_command_cmd "$@" ;;
    help|-h|--help) usage ;;
    *) echo "vscode-ssh: unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
