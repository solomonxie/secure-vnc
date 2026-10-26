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
- **Reverse** terminal hosts, for a server without Remote Login: on the same Wi-Fi the app is a small SSH server while open, and the server's own `ssh` connects in with its key (pasted into the app): `mkfifo /tmp/f; ssh -p2222 <iphone> </tmp/f | script -q /dev/null zsh -l >/tmp/f` (wrap in a `while :; do …; sleep 2; done` loop to reconnect whenever the app listens again). The app then types a bootstrap into that shell: a throwaway sshd on 127.0.0.1, as that user, authorizing only this iPhone's key, reached through the same pipe. Full terminal (files, tmux, Claude); nothing set up there beyond the key.
- **This iPhone**: a built-in shell and file browser for the phone itself. iOS lets no app run other programs, so ~80 GNU-style commands are built in (Swift): `ls cd cp mv rm mkdir find grep sed sort uniq cut tr wc head tail du df stat file xxd base64 sha256sum curl wget tee test …`, with quotes, `$VAR`, globs, pipes, redirects, `&&`/`||`; `help` lists them, `open`/`edit FILE` previews or edits. One tree: `/Documents` (= `~`, also in the Files app), `/tmp`, and any folder or USB drive / SD card linked from the Files app (kept as a bookmark, back when replugged).
- File browser previews pictures, videos, PDFs and documents in Quick Look (swipe through a folder's pictures; remote files are downloaded first), with thumbnails and Share for local files.
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
