# `sidecarctl` source component

This directory contains the Swift command-line client used by Sidecar Auto.
It is a small, dependency-free wrapper around macOS's private
`SidecarCore` Objective-C classes.

The public entry point is `Sources/CLI/main.swift`; shared framework probing,
state snapshots and recovery code live in `Sources/Shared/`. The project
installer builds this component with:

```sh
./build.sh --cli-only --build-only
```

The build follows the host architecture by default. Release packaging can set
`TARGET_ARCH=arm64` or `TARGET_ARCH=x86_64` (and `TARGET_OS_VERSION=13.0`) to
produce one slice at a time before combining slices with `lipo`.

The component is derived from the MIT-licensed
[sidecar-reconnect](https://github.com/craigblewett/sidecar-reconnect) project.
Keep [`LICENSE`](LICENSE) with these files. The project [`NOTICE.md`](../../docs/NOTICE.md)
records the provenance and the local changes.

The command requires macOS 13+ and Xcode Command Line Tools. It is not expected
to work on Linux or Windows because the framework is private and is present only
on macOS.
