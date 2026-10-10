# Secure VNC — Mac Screen Sharing over SSH on iPhone

Native Swift iPhone app: SSH key auth → tunnel → VNC, in one tap. The same as

```sh
ssh -N -L 127.0.0.1:5901:localhost:5900 user@mac   # + a VNC viewer on :5901
```

but without a local port: VNC runs inside an SSH `direct-tcpip` channel in-process.

## Features
- SSH keys generated on the phone — **Secure Enclave P-256** (non-exportable) or **Ed25519** (Keychain, this device only); optional Face ID gate.
- Copy / share the public key, or a one-line `authorized_keys` install command.
- Host keys trusted on first use (`SHA256:` fingerprint); a changed key blocks the connection.
- VNC auth: macOS account (Apple ARD, type 30), VNC password, or none. Encodings: ZRLE, CopyRect, Raw, cursor, resize.
- **Terminal** host type: line-based shell on a `dumb` pty — live output, selectable text, sudo/password and y/n prompts, ^C/^D, command history; console kept across reconnects; wrap at screen width, 160 columns or not at all (sideways scroll), pinch to zoom.
- Talk to one tmux pane without attaching: pick it from a list; its text is mirrored and commands are typed into it (`capture-pane`/`send-keys`).
- Talk to a running **Claude Code** session: pick it by name (from `~/.claude/sessions`); its transcript `.jsonl` is shown as clean prompt / reply / tool lines instead of the TUI, messages are typed into its tmux pane, esc interrupts, and a screen peek shows permission prompts.
- File browser from the terminal's current folder: browse, view/edit text, copy/cut/paste, rename, delete, new folder, cd there — plain `sh` over the same SSH connection, no SFTP needed.
- Sessions survive a quick trip to another app; a link iOS dropped reconnects on return.
- Trackpad or direct-touch control, pinch zoom, two-finger scroll/right click, keyboard with esc/tab/⌃⌥⌘/arrows bar, hardware keyboard.
- No third-party services; dependencies: [swift-nio-ssh](https://github.com/apple/swift-nio-ssh), [BigInt](https://github.com/attaswift/BigInt).

## Set up the Mac
1. System Settings → General → Sharing → **Remote Login** and **Screen Sharing** on.
2. In the app: Keys → + → Generate → **Copy install command** → run it on the Mac (or append the public key to `~/.ssh/authorized_keys`).
3. Hosts → + → SSH host/user/key, VNC `localhost:5900`, Auth **macOS** + your Mac login.

## Build
Requires Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # your Team ID + bundle id
make device      # build, install and launch on the connected iPhone
make test        # library tests on macOS
make test-live   # + throwaway sshd on 127.0.0.1:2222 tunnelling to this Mac's Screen Sharing
```

Design notes: `docs/design/secure-vnc/`.
