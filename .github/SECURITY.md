# Security policy

## Scope

This project controls Sidecar through Apple's private macOS frameworks and
installs per-user command-line helpers. It does not collect telemetry or send
credentials to a server. Logs are written locally under `~/Library/Logs/` and
may contain device names and connection errors.

The installer does not request an administrator password, disable FileVault,
type a login password, grant TCC permissions, or create a network service. Review
scripts before running them if you received this project from an untrusted
source.

## Reporting a vulnerability

Please do not publish credentials, private logs, device serial numbers or an
unpatched exploit in a public issue. Open a private GitHub security advisory if
that feature is enabled for the repository. Otherwise contact the repository
maintainer through the private contact method listed in the GitHub profile and
include:

- affected macOS version and hardware architecture;
- the exact release or commit;
- reproduction steps that do not include secrets;
- relevant redacted output from `sidecar-doctor.sh`.

Do not send passwords, Apple Account data, pairing tokens, or complete private
logs. This project cannot promise a response time or support versions of macOS
that have changed the private Sidecar API.

## Local data hygiene

Before attaching diagnostics, inspect them for iPad names, USB serial numbers,
local paths and account names. The public repository intentionally excludes
build products, logs, device dumps and configuration files.
