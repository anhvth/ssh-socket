# SSH Bridge Architecture

`ssh-bridge` is the canonical foundation for features that need a command on a remote SSH machine to perform an action on the local laptop.

Examples:

```text
remote ss-code .      -> local code --remote ssh-remote+<ssh-host> <path>
remote ss-open file  -> local rsync to /tmp/remote_<host>/... then open locally
remote ss-copy       -> local pbcopy / wl-copy / xclip / xsel
remote future-app -> local future handler
```

## Core idea

```text
normal ssh session
LocalCommand on the local machine
local ssh-bridge daemon
background SSH reverse tunnel
remote /tmp/ssh-bridge state
small remote command clients
JSON request protocol
local app handlers
```

The remote machine does not need VS Code or a clipboard app. It only needs `python3` and the tiny bridge client commands installed in `~/.local/bin`.

## Runtime locations

Local machine:

```text
~/.cache/ssh-bridge/bridge.sock
~/.cache/ssh-bridge/bridge.pid
~/.cache/ssh-bridge/bridge.log
```

Remote machine:

```text
/tmp/ssh-bridge/$USER/$HOSTNAME/tcp
/tmp/ssh-bridge/$USER/$HOSTNAME/ssh_host
```

Remote state intentionally lives in `/tmp` because many worker fleets share `$HOME` over NFS while `/tmp` is per machine.

## SSH config contract

Each host that should support bridge apps needs this in the local Mac `~/.ssh/config` Host block:

```sshconfig
Host jump
    PermitLocalCommand yes
    LocalCommand /Users/anhvth/dotfiles/mybins/ss-bridge local-command %n %r
    SetEnv _SSH_BRIDGE_HOST=%n
Host wk wk2 worker-*
    PermitLocalCommand yes
    LocalCommand /Users/anhvth/dotfiles/mybins/ss-bridge local-command %n %r
    SetEnv _SSH_BRIDGE_HOST=%n
```

Use the SSH config `Host` name, for example `jump` or `wk`, not the remote machine hostname such as `ducle-ThinkPad-E14-Gen-7` or `worker-21`.

## What happens when you run ssh

When you run:

```bash
ssh jump
```

OpenSSH connects normally, then runs `LocalCommand` on the local Mac. The bridge local-command does this:

```text
1. Start ~/.cache/ssh-bridge/bridge.sock daemon if needed.
2. SSH into the same host without LocalCommand recursion.
3. Install/update remote clients: ss-bridge, ss-code, ss-open, ss-open-remote, ss-copy, ss-pbcopy.
4. Write /tmp/ssh-bridge/$USER/$HOSTNAME/tcp.
5. Write /tmp/ssh-bridge/$USER/$HOSTNAME/ssh_host.
6. Check whether the reverse tunnel already works.
7. If needed, start a background ssh -R tunnel.
8. Return control to the original interactive ssh session.
```

After that, the normal remote shell can run:

```bash
ss-code .
ss-open /tmp/easy_to_read.html
printf hello | ss-copy
```

## Request protocol

Every remote app sends one JSON line to the local daemon through the tunnel.

Ping:

```json
{"type":"ping"}
```

Open VS Code Remote-SSH:

```json
{"type":"vscode.open","path":"/home/ducle/project","ssh_host":"jump","remote_machine_hostname":"ducle-ThinkPad-E14-Gen-7","user":"ducle"}
```

Write local clipboard:

```json
{"type":"clipboard.write","text":"hello","ssh_host":"jump","remote_machine_hostname":"ducle-ThinkPad-E14-Gen-7","user":"ducle"}
```

The local daemon returns one JSON line:

```json
{"status":"ok","type":"clipboard.write","bytes":5}
```

or:

```json
{"status":"error","message":"local machine has no clipboard writer"}
```

## Base commands

Local daemon lifecycle:

```bash
ss-bridge bridge start
ss-bridge bridge status
ss-bridge bridge stop
ss-bridge bridge serve
```

SSH bootstrap command used by `LocalCommand`:

```bash
ss-bridge local-command <ssh-config-host> [ssh-user]
```

Generic remote request helper:

```bash
ss-bridge send <request-type> '{"field":"value"}'
```

Application commands:

```bash
ss-bridge code [path] [--vvv]
ss-bridge copy [--vvv] < stdin
```

Compatibility wrappers:

```bash
ss-code [path]
ss-copy < stdin
ss-pbcopy < stdin
ss-bridge bridge status
ss-bridge local-command jump ducle
```

## How to add a future application

A new application needs two pieces: a remote client command and a local daemon handler.

Remote client responsibilities:

```text
1. Parse CLI arguments.
2. Resolve remote paths or read stdin if needed.
3. Load bridge context from /tmp/ssh-bridge/$USER/$HOSTNAME.
4. Build one JSON payload with a unique type name.
5. Call send_json payload request_name debug.
6. Print useful diagnostics if the bridge is missing.
```

Local handler responsibilities:

```text
1. Validate required JSON fields.
2. Resolve local executable dependencies.
3. Perform the local action without blocking the daemon forever.
4. Return {"status":"ok", ...} or {"status":"error", "message":"..."}.
5. Never trust the remote payload as shell code.
```

Naming rules:

```text
Use dotted request types, such as vscode.open, clipboard.write, browser.open, file.reveal.
Use ssh_host for the local ~/.ssh/config Host alias.
Use remote_machine_hostname only for diagnostics.
Use path for remote absolute paths.
Use text for clipboard-like UTF-8 payloads.
```

Implementation checklist:

```text
1. Add a handler function in the embedded Python daemon.
2. Register it in HANDLERS.
3. Add a shell command function that constructs the JSON payload.
4. Add the command to the case statement.
5. Add the installed command name to install_remote_script and install-vsc.sh if it should exist as a top-level remote command.
6. Document the request type and examples in this file.
7. Test local daemon status, remote --vvv output, and the missing-bridge error path.
```

## Existing applications

`vscode.open`:

```text
Remote command: ss-code [path]
Local action: code --remote ssh-remote+<ssh_host> <path>
Required local dependency: /usr/local/bin/code, code, or code-insiders
```

`file.open`:

```text
Remote command: ss-open [path] or ss-open-remote [path]
Local action: rsync <ssh_host>:<path> /tmp/remote_<ssh_host>/<path> then open/xdg-open
Required local dependency: rsync and open/xdg-open
```

`clipboard.write`:

```text
Remote command: ss-copy < stdin, ss-pbcopy < stdin
Local action: pbcopy, wl-copy, xclip, or xsel
Fallback: local remote clipboard tools or OSC 52 if the bridge is missing
```

## Troubleshooting

If a remote command says the bridge is missing, fix the local SSH config first. `curl | sh` only installs the remote client commands. It cannot configure your local Mac SSH `LocalCommand`.

Install or refresh remote clients manually:

```bash
curl -fsSL https://raw.githubusercontent.com/anhvth/ssh-socket/refs/heads/main/install-vsc.sh | sh
```

Then reconnect from the local Mac:

```bash
ssh <ssh-config-host>
```

Debug remote request:

```bash
ss-code . --vvv
printf hello | ss-copy --vvv
```

Check local daemon:

```bash
ss-bridge bridge status
```
