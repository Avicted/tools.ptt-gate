# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-07

### Added
- `ptt-gate` daemon: while a key (default `KEY_F24`) is held on the keyd virtual
  keyboard the default source is unmuted, otherwise it is muted. Reads evdev
  without grabbing, so it works under Wayland whatever window has focus.
- Single-threaded libpulse main loop; mutes on start, on exit and when the input
  device disappears, and re-finds the device if keyd restarts.
- Command-line options `--device`, `--key`, `--source`, `--verbose`, `--help`,
  `--version`; exit codes 0, 1 (runtime failure) and 2 (usage error).
- `make setup` / `make doctor` scripts, a keyd config and a systemd user unit.
- cmocka unit tests, ASan/UBSan/valgrind targets, static analysis, hardening
  checks and CI.
- `make dist` source tarball with checksum.
