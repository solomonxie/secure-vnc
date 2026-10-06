# Secure VNC — Implementation Plan

## Phase 1: Core library
Protocol and crypto first — testable on macOS with `swift test`, no UI needed.

- [x] T1.1 Package scaffold — SPM, NIO SSH + BigInt deps — see `SecureVNCKit` — depends: none
- [x] T1.2 SSH keys — generate SE P-256 / Ed25519, Keychain storage, OpenSSH public key + fingerprint — see `SecureVNCKit/Sources/SecureVNCKit/Keys` — depends: T1.1
- [x] T1.3 SSH tunnel — connect, pubkey auth, TOFU host-key callback, `direct-tcpip` byte transport — see `SecureVNCKit/Sources/SecureVNCKit/SSH` — depends: T1.1
- [x] T1.4 RFB client — handshake, auth 1/2/30, ServerInit, input events, update loop — see `SecureVNCKit/Sources/SecureVNCKit/RFB` — depends: T1.1
- [x] T1.5 Decoders — Raw, CopyRect, ZRLE (persistent zlib), DesktopSize, Cursor — see `SecureVNCKit/Sources/SecureVNCKit/RFB` — depends: T1.4
- [x] T1.6 Tests — key encoding, ZRLE, fake-server handshake, temp-sshd tunnel to local :5900 — see `SecureVNCKit/Tests` — depends: T1.2–T1.5

## Phase 2: App
UI over the library; needs the session API from Phase 1.

- [x] T2.1 Project — XcodeGen, signing via gitignored `Local.xcconfig`, Info.plist (scene, local network, Face ID) — see `project.yml` — depends: T1.1
- [x] T2.2 Stores — hosts JSON, secrets in Keychain — see `SecureVNC/Model` — depends: T1.2
- [x] T2.3 Hosts, Host editor, Keys, Key detail screens — see `UIUX_DESIGN.md` — depends: T2.2
- [x] T2.4 Session screen — framebuffer view, gestures, keyboard + key bar, states/alerts — see `SecureVNC/Session` — depends: T1.3–T1.5, T2.2
- [x] T2.5 Icon — generated light/dark/tinted — see `scripts/make-icon.swift` — depends: none

## Phase 3: Ship to device
- [x] T3.1 `make device` — release build, install, launch on the connected iPhone — see `Makefile` — depends: T2.*
- [ ] T3.2 On-device check against the Mac — key install, TOFU, ARD auth, gestures, ⌘ mapping — depends: T3.1
