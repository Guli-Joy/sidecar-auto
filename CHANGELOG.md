# Changelog

## Unreleased

- Prepared a clean public source distribution for Sidecar Auto.
- Added a documented one-command installer, read-only doctor, USB transport
  detection, wireless preflight and headless BetterDisplay setup.
- Removed generated binaries, logs and machine-specific identifiers from the
  source distribution.
- Documented licensing and attribution for the retained `sidecarctl` source.

## 2026-09-30

- Added the `sidecarctl snapshot` path used by the one-shot controllers.
- Added explicit USB (`ForceUSB`) and direct wireless (`ForceAWDL`) selection.
- Added audible and Chinese speech feedback for progress, success and failure.
- Added conservative guards against unknown state, duplicate device names and
  taking over another active iPad session.

This project follows calendar dates for release notes. A release is only
considered wireless or headless verified when the README records the exact
hardware, macOS version and test conditions.
