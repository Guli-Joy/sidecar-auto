# Third-party notices

Sidecar Auto combines original automation scripts and helper sources with the
retained upstream-derived `sidecarctl` component in
[`vendor/sidecarctl/`](vendor/sidecarctl/).

## Original automation

The automation under `scripts/`, the helper sources under `Sources/`, the
installer, templates and documentation are Copyright (c) 2026 Guli-Joy and are
available under the MIT License in [`LICENSE`](LICENSE).

## `sidecarctl` source

The Swift Sidecar CLI sources retained under `vendor/sidecarctl/` are
derived from the MIT-licensed project by Craig Blewett:

- Upstream: <https://github.com/craigblewett/sidecar-reconnect>
- Copyright notice and license: [`vendor/sidecarctl/LICENSE`](vendor/sidecarctl/LICENSE)

That component's local changes remain covered by its original MIT notice. Do not
remove or replace that notice when redistributing the nested component.

## Apple and BetterDisplay

Sidecar, SidecarCore, Handoff, AirDrop/AWDL and macOS are Apple trademarks or
services. BetterDisplay is an independent third-party application. This project
is not affiliated with or endorsed by Apple or BetterDisplay. Their names are
used only to describe compatibility and required integrations.
