# `sidecarctl` source component

This directory contains the Swift command-line client used by Sidecar Auto.
It is a small, dependency-free wrapper around macOS's private
`SidecarCore` Objective-C classes.

The public entry point is `Sources/CLI/main.swift`; shared framework probing,
state snapshots and recovery code live in `Sources/Shared/`. The root installer
builds this component with:

```sh
./build.sh --cli-only --build-only
```

The component is derived from the MIT-licensed
[sidecar-reconnect](https://github.com/craigblewett/sidecar-reconnect) project.
Keep [`LICENSE`](LICENSE) with these files. The root [`NOTICE.md`](../../NOTICE.md)
records the provenance and the local changes.

The command requires macOS 13+ and Xcode Command Line Tools. It is not expected
to work on Linux or Windows because the framework is private and is present only
on macOS.
