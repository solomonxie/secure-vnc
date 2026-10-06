# Secure VNC — Design

## Problem
Exposing a Mac's Screen Sharing (VNC, port 5900) to the network is weak: VNC's own crypto is old, and the port is a target. The safe pattern is an SSH tunnel (`ssh -N -L 5901:localhost:5900 user@mac`), but on iPhone that means two apps (SSH client + VNC viewer) juggling a local port, and keys pasted around.

## Goals
- One native iPhone app: SSH key auth → tunnel → VNC screen, one tap.
- Generate and keep SSH keys on the device; private key never leaves it.
- VNC traffic only ever travels inside SSH; nothing listens on a port.
- Works with the built-in macOS Screen Sharing server out of the box.

## Non-goals
- Password SSH auth, importing existing private keys, jump hosts.
- Direct (untunnelled) VNC.
- iPad/macOS layouts, file transfer, audio, multi-monitor selection.
- Clipboard sync (v2).

## Use cases
| # | Story | Scenario → result | Failure branches |
|---|---|---|---|
| U1 | As the owner, I want a key made on my phone, so no private key is ever copied around | Keys → Generate → name → public key shown → Copy / Share → paste into `~/.ssh/authorized_keys` | — |
| U2 | Add my Mac once | Hosts → + → SSH host/user/key, VNC target `localhost:5900`, macOS account → Save | Missing field → Save disabled |
| U3 | See my Mac's screen | Tap host → Face ID (if key requires) → SSH → host key check → tunnel → VNC auth → live screen | Unreachable · key rejected (show the public key to install) · host key changed (block) · Screen Sharing off · VNC auth failed |
| U4 | First connect trusts the server once | Unknown host key → fingerprint `SHA256:…` shown → Trust → saved | Later mismatch → hard stop, no "continue anyway" |
| U5 | Control it | Trackpad mode: drag moves cursor, tap = click, 2-finger tap = right click, 2-finger drag = scroll, pinch = zoom, long-press-drag = drag. Keyboard + Esc/Tab/⌃⌥⌘/arrows bar | — |
| U6 | Lost phone | Keys bound to this device (Secure Enclave / `ThisDeviceOnly`), optional Face ID gate; remove the line from `authorized_keys` to revoke | — |

## Options considered
- **Bundle a VNC lib (libvncclient) + libssh2 (C)** — proven, but C build glue, OpenSSL, larger attack surface.
- **Local port forward + any VNC client code** — mirrors the shell command, but opens a listening socket other apps on the device could hit.
- **SwiftNIO SSH + own RFB client** — pure Swift, Apple-maintained SSH, channel piped in-process. ✓

## Decision
SwiftNIO SSH, `direct-tcpip` channel straight to the VNC target; the RFB client reads/writes that channel. Equivalent to `ssh -N -L …` without the local listener.
- Keys: **Secure Enclave P-256** (default, non-exportable, ECDSA) or **Ed25519** (Keychain, `WhenUnlockedThisDeviceOnly`). NIO SSH has no RSA — fine, OpenSSH accepts both.
- Host keys: trust on first use, SHA256 fingerprint in OpenSSH format.
- RFB 3.8; auth: None (1), VNC password (2, DES), **Apple ARD (30, DH + AES-128)** — the probed Mac offers only 30/33/35/36.
- Encodings: ZRLE, CopyRect, Raw + DesktopSize and Cursor pseudo-encodings.

## Data & integrations
- Hosts: JSON in Application Support (no secrets).
- Secrets (private keys, VNC/macOS passwords): Keychain, `…ThisDeviceOnly`, per host/key id.
- Known host keys: in host record (public data).
- Deps (SPM): `swift-nio-ssh` (Apple), `BigInt` (attaswift, ARD DH math). No network calls besides the user's own SSH server.

## Risks / open questions
- ARD DH uses a 4096-bit prime — modpow cost on-device; needs release build.
- Command key mapping on Apple's server (Meta_L vs Super_L) — verify on device.
- Full Retina framebuffer over Wi-Fi: ZRLE keeps it workable; Raw fallback is slow.
- iOS kills sockets in background — reconnect on return, no background keep-alive.
