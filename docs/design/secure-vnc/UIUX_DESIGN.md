# Secure VNC — UI/UX

Product reasoning: `DESIGN.md`. Stories U1–U6 live there; every screen below traces to one.

## Screen map
```
      Launch
        │
        ▼
    ┌ Hosts ┐──tap row──▶ Session (full screen) ──Disconnect──▶ Hosts
    │       │──+ / Edit──▶ Host editor (sheet)
    │  🔑 ──┼──▶ Keys ──Generate──▶ New key (sheet)
    └───────┘          └─tap row──▶ Key detail ──▶ [share sheet]
```

## Hosts (home) — U2, U3
```
Secure VNC                    🔑   +
───────────────────────────────────
╭─────────────────────────────────╮
│ 🖥 Studio Mac                   │
│ alex@192.168.1.20 → :5900 │ ›
├─────────────────────────────────┤
│ 🖥 Office Mini                  │
│ admin@mini.local → :5900        │ ›
╰─────────────────────────────────╯
 swipe ◀ row ⇒ Edit · Delete!
```
```
empty   No hosts yet
        Add your Mac to connect over SSH.
        [[ Add host ]]
no key  Hosts listed; editor's Key picker shows "Generate a key first" → Keys
```

## Host editor (sheet) — U2
```
( Cancel )     New Host        ( Save )·   ← disabled until name, host, user, key set
NAME
│ Studio Mac                      │
SSH
│ 192.168.1.20                    │
│ 22                              │   port
│ alex                            │   user
Key                    iPhone SE ⌄  ← unfolds in place
VNC  ⓘ                                 ⓘ: reached from the SSH server, like -L …:localhost:5900
│ localhost                       │
│ 5900                            │
Auth          [ MACOS | VNC | None ]
│ alex                            │   macOS user (macOS only)
│ ••••••••                    👁  │   password, Keychain
```
Fields: autocorrect/autocapitalize off.

## Keys — U1, U6
```
‹ Hosts          Keys            +
╭─────────────────────────────────╮
│ iPhone SE        Secure Enclave │ ›
│ SHA256:q3x9…Fz0   Face ID       │
├─────────────────────────────────┤
│ backup           Ed25519        │ ›
│ SHA256:Lm2a…7cQ                 │
╰─────────────────────────────────╯
empty   No keys yet   [[ Generate key ]]
```

### New key (sheet)
```
( Cancel )     New Key      ( Generate )
│ iPhone                          │   name
Type   [ SECURE ENCLAVE | Ed25519 ]
Require Face ID                 ─●
```

### Key detail
```
‹ Keys         iPhone SE
ecdsa-sha2-nistp256 AAAAE2Vj…    ← monospace, selectable, 4 lines max
[[ Copy public key ]]  [ Share… ]
Copy install command               ← echo '…' >> ~/.ssh/authorized_keys
SHA256:q3x9…Fz0
Delete key!                        ← alert: "Hosts using it can't connect."
```

## Session — U3, U4, U5
```
┌─────────────────────────────────┐
│ ✕   Studio Mac   ⌨  🖱/👆      │ ← overlay bar, fades after 3 s, tap top edge to show
│                                 │
│        remote screen            │
│      (pinch to zoom, ↖ cursor)  │
│                                 │
├─────────────────────────────────┤
│ esc tab ⌃ ⌥ ⌘ ← ↑ ↓ →           │ ← above keyboard when ⌨ on; ⌃⌥⌘ sticky (one key)
└─────────────────────────────────┘
```
```
connecting  ⟳ Connecting to 192.168.1.20…  → Authenticating… → Opening tunnel… → Starting VNC…   ( Cancel )
host key    alert: "Trust Studio Mac?"  ED25519 SHA256:…  ( Cancel ) [[ Trust ]]
key changed ⚠ Host key changed — possible attack. Expected SHA256:a…, got SHA256:b…   [[ Close ]]
ssh denied  ⚠ Key not accepted by alex@192.168.1.20  [ Copy install command ] [[ Close ]]
no vnc      ⚠ Couldn't reach localhost:5900 — is Screen Sharing on?   [[ Retry ]]
vnc auth    ⚠ macOS login rejected   ( Edit host ) [[ Retry ]]
dropped     ⚠ Disconnected   ( Close ) [[ Reconnect ]]
```

## Gestures
| Mode | Gesture | Result |
|---|---|---|
| Trackpad 🖱 (default) | 1-finger drag | move cursor (relative) |
| | tap / 2-finger tap | left / right click |
| | double-tap | double click |
| | long-press then drag | drag with button held |
| Touch 👆 | tap | click at finger |
| | 1-finger drag | pan zoomed view |
| | long-press | right click |
| Both | 2-finger drag | scroll |
| | pinch | zoom 1×–5× |

## Deviations from `uiux`
None.
