# ssh-tmux-copy / ssh-bridge

This repo provides a small canonical bridge for remote SSH commands that need to perform local laptop actions.

It currently powers:

```text
ss-code .             -> opens local VS Code Remote-SSH at the remote path
ss-copy < stdin      -> writes remote tmux/copy output to the local clipboard
ss-pbcopy < stdin    -> alias for ss-copy
```

The shared primitive is:

```text
SSH LocalCommand + local daemon + reverse SSH tunnel + /tmp remote state + JSON request handlers
```

Read the full architecture and extension guide here:

```text
BRIDGE.md
```

## Remote install

On a remote machine, install the small client commands with:

```bash
curl -fsSL https://raw.githubusercontent.com/anhvth/ssh-socket/main/install-vsc.sh | sh
```

This installs:

```text
~/.local/bin/ss-bridge
~/.local/bin/ss-code
~/.local/bin/ss-open
~/.local/bin/ss-open-remote
~/.local/bin/ss-copy
~/.local/bin/ss-pbcopy
```

The remote machine does not need VS Code. It needs `python3` for bridge requests.

## Local SSH config

The remote install only installs client commands. Your local Mac must still create the bridge when you connect.

Add this to each local `~/.ssh/config` Host block that should support bridge apps:

```sshconfig
Host jump
    PermitLocalCommand yes
    LocalCommand /Users/anhvth/dotfiles/mybins/ss-bridge local-command %n %r
    SetEnv _SSH_BRIDGE_HOST=%n
```

Then reconnect:

```bash
ssh jump
```

After reconnecting, these should work in the remote shell:

```bash
ss-code .
printf hello | ss-copy
```

## Tmux integration

Use `copy` as the tmux copy-pipe target:

```tmux
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "$HOME/dotfiles/utils/copy"
```

In this dotfiles repo, `utils/copy` is a wrapper around the canonical bridge copy app.

## Troubleshooting

If the remote command says the bridge is missing, fix local SSH config first. `curl | sh` does not configure your local Mac.

Useful checks:

```bash
ss-bridge bridge status
ss-code . --vvv
printf hello | ss-copy --vvv
```
