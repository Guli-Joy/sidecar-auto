# Changelog

## Unreleased

- Added a first-run configuration wizard, USB iPad scanning with automatic target
  field filling, separate Mac/iPad readiness messaging, and live connection-stage
  feedback in the manual test view.
- Added safe USB detector regression tests to CI.

- Prepared a clean public source distribution for Sidecar Auto.
- Added the native SwiftUI `Sidecar Auto Setup.app` build, with a visual
  configuration guide, prebuilt runtime resources, status checks, and explicit
  one-shot connect/disconnect controls.
- Added universal App packaging, DMG creation, release signing guidance, and a
  security model that separates Bluetooth authorization from radio state and
  documents FileVault, Handoff, Shortcuts, and BetterDisplay limits.
- Added a documented one-command installer, read-only doctor, USB transport
  detection, wireless preflight and headless BetterDisplay setup.
- Removed generated binaries, logs and machine-specific identifiers from the
  source distribution.
- Documented licensing and attribution for the retained `sidecarctl` source.
- Added the built-in resident virtual-display helper with `auto`, `builtin`,
  and `betterdisplay` backend selection. The built-in profile is intentionally
  fixed and its undocumented macOS API compatibility is called out.
- Redesigned the setup app with a sidebar workflow, a focused overview, grouped
  device/display/shortcut settings, clearer status pills, one-shot test controls,
  and a bundled Sidecar Auto app icon.
- Added an explicit Bluetooth permission flow: the app triggers the native macOS
  confirmation only after the user clicks, refreshes after returning from Settings,
  and avoids requesting unnecessary Accessibility or Screen Recording access.
- Added one-click Shortcut template generation: the app installs the local helper,
  signs the two shell-action templates, and opens Apple's confirmation flow one at a
  time. Added the current macOS 27 AirDrop/Handoff settings deep link and separate
  FileVault and automatic-login guidance.

## 2026-09-30

- Added the `sidecarctl snapshot` path used by the one-shot controllers.
- Added explicit USB (`ForceUSB`) and direct wireless (`ForceAWDL`) selection.
- Added audible and Chinese speech feedback for progress, success and failure.
- Added conservative guards against unknown state, duplicate device names and
  taking over another active iPad session.

This project follows calendar dates for release notes. A release is only
considered wireless or headless verified when the README records the exact
hardware, macOS version and test conditions.
