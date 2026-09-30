# Sidecar Auto

Sidecar Auto is a macOS one-shot controller for an iPad used as an Apple
Sidecar display. A macOS Shortcut invokes the controller; it detects a unique
iPad USB data device and requests `ForceUSB`, or prepares the Mac radios and
requests `ForceAWDL` when no iPad cable is present.

## What it does

- keeps a physical monitor path as a normal extended-display setup;
- creates and verifies an independent BetterDisplay virtual screen for a
  headless Mac when needed;
- refuses unknown state, ambiguous iPad names, and another active iPad session;
- plays progress/success/failure sounds and optional Chinese speech;
- performs one connection request and verifies both Sidecar state and an online
  display; it does not retry forever or seize a shared iPad in the background.

## Install

macOS 13+ and Xcode Command Line Tools are required. Copy the repository to the
Mac, then run:

```sh
./install-sidecar-auto.sh
```

The installer builds `sidecarctl`, the display probe and the Bluetooth helper,
then installs them under `~/.local/bin`. It does not install BetterDisplay,
create Shortcuts, grant TCC permissions or change FileVault settings.

Create a macOS Shortcut with a **Run Shell Script** action:

```sh
exec "$HOME/.local/bin/sidecar-connect-once.sh" auto
```

Use the explicit `wired` or `wireless` arguments for troubleshooting. See the
[Chinese guide](README.md), [architecture](docs/ARCHITECTURE.md), and
[troubleshooting](docs/TROUBLESHOOTING.md) for the complete setup.

## Limitations

Sidecar Auto calls Apple's private `SidecarCore` API and can break after a
macOS update. The iPad must be awake and unlocked. Wireless direct mode still
requires Wi-Fi, Bluetooth, Handoff, the same Apple Account and Apple's
Continuity conditions. FileVault and the login screen cannot be automated by a
LaunchAgent. BetterDisplay is a separate product and headless CLI operations
may require its Pro/trial entitlement.

The root automation is MIT licensed. The retained `sidecarctl` source carries
the upstream MIT notice; see [NOTICE.md](NOTICE.md).
