# Contributing

Thanks for helping improve Sidecar Auto.

## Before opening a change

- Read the root [`README.md`](README.md) and the component notes in
  [`Sources/sidecarctl/README.md`](Sources/sidecarctl/README.md).
- Keep changes compatible with the documented macOS baseline (macOS 13+ unless
  the change states a narrower requirement).
- Do not commit compiled binaries, app bundles, logs, `.DS_Store` files, swap
  files, personal device names, USB serial numbers, account data or absolute
  paths from a developer's home directory.
- Preserve the upstream MIT notice in `Sources/sidecarctl/LICENSE`.

## Validation

On a Mac with Xcode Command Line Tools installed, run:

```sh
bash -n ./*.sh
./Sources/sidecarctl/build.sh --cli-only --build-only
```

The root installer performs the same checks plus parallel builds of the CLI,
display probe and Bluetooth helper:

```sh
./install-sidecar-auto.sh
```

Do not run a real Sidecar connection in CI. A real test needs an awake, unlocked
iPad and can take over a user's display, so describe the hardware and macOS
version when reporting one.

## Pull requests

Keep one behavior change per pull request where possible. Explain the user
visible change, the affected transport (USB or AWDL), the test commands and any
known macOS or permissions limitation. Do not claim wireless or headless support
was tested unless the exact conditions are recorded.
