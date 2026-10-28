# Ciaobot for Mac

An optional macOS client for a separately installed Ciaobot server. The client
does not bundle, install, manage, or replace the server or its workspace.

The intended experience is a Mac app window and menu bar connected to a local
or remote server, with native notifications. The existing web interface remains
available independently, including on phones and other computers.

## Prior implementation

The retired Tauri desktop app is available in the `ciaobot` repository at
commit `20d2c23f^`, under `desktop/`. Its tray and native notification code
are useful references. Its bundled runtime, installer, server ownership, and
update assumptions belong to the retired product and must not be copied
blindly. Reuse is subject to compatibility and security review.

This repository is an early starting point; it does not yet contain a working
client or a configured remote.
