# ssh-tmux-copy

A lightweight, robust utility to synchronize your remote tmux copy selections directly to your local system's clipboard. It works out-of-the-box over SSH using OSC 52, with a background agent (`clipsync`) fallback for terminals that do not support or allow OSC 52.

## Features
- **Zero-config OSC 52:** Directly pipes tmux copy buffers to your terminal emulator's native clipboard interface.
- **Transparent local sync (`clipsync`):** Automatically starts a background agent when you ssh to monitor copies and sync them using your laptop's native clipboard tools (`pbcopy`, `wl-copy`, `xclip`, `xsel`).
- **Standard mouse copy:** Double-click to copy a word, triple-click to copy a line, or click-drag to select text.
- **Vim-style selections:** Normal keybindings like `y` and `Enter` in copy mode sync to the system clipboard automatically.

---

## Installation

Run the following installation scripts. Make sure to replace `YOUR_GITHUB_USERNAME` and `YOUR_REPO_NAME` with your repository details once created on GitHub.

### 1. On your Local Machine (Client/Laptop)
Run this command to install the SSH shell wrapper and `clipsync` daemon:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/install.sh | bash -s -- --local
```

This will:
- Install files to `~/.ssh-tmux-copy/`.
- Add shell integration to your `~/.zshrc` or `~/.bashrc` to hook the `ssh` command.
- Open a background tmux pane (`tmux-sync-clipboard` session) to sync your clipboards whenever you SSH.

### 2. On the Remote Machine (Server)
Run this command on each remote server to install the tmux configuration and clipboard copy wrapper:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/install.sh | bash -s -- --remote
```

This will:
- Install `copy` and `clipwatch` to `~/.ssh-tmux-copy/bin/`.
- Configure `~/.ssh-tmux-copy/tmux-copy.conf`.
- Source the configuration in your `~/.tmux.conf` file automatically.

*Note: Reload tmux configuration with `tmux source-file ~/.tmux.conf` (or prefix + `r`) on the remote server after installing.*

---

## How it works

1. **Local copy dispatcher (`copy`):** When you copy in tmux on the remote machine (visual selection, click-drag, etc.), the text is piped to `~/.ssh-tmux-copy/bin/copy`. It saves the last selection to `/tmp/tmux_copy_text_select`.
2. **OSC 52 Escape Sequence:** `copy` attempts to send an OSC 52 escape code back to the terminal. If your local terminal emulator (WezTerm, iTerm2, Kitty, Alacritty, Windows Terminal) supports OSC 52, it intercepts the sequence and sets your laptop's clipboard.
3. **Background Synchronizer (`clipsync`):** If your terminal doesn't support or blocks OSC 52, the local `ssh` wrapper runs `clipsync` in the background. It maintains an SSH channel that watches `/tmp/tmux_copy_text_select` on the remote server and streams any selection changes back to your local clipboard utility (`pbcopy`, `wl-copy`, `xclip`, or `xsel`) in real time.

---

## Troubleshooting

- **Copy does not work over SSH:**
  - Check if your terminal supports OSC 52. If using iTerm2, verify that **Settings → General → Selection → "Applications in terminal may access clipboard"** is checked.
  - If you need the `clipsync` fallback, verify that tmux is installed on your local machine and that your shell wrapper is active by running:
    ```bash
    clipsync-status
    ```
- **Old config still active:** Run `tmux kill-server` on the remote host to pick up configuration changes.
- **Select text without copying:** Hold `Shift` while dragging to bypass tmux's mouse handling and use your terminal's native selection.
