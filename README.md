# ptt-gate

Push-to-talk for Discord on KDE Plasma Wayland that works even while a Proton
game has focus. Hold Caps Lock and the mic is live. Let go and it's muted.

Built for one setup: KDE Plasma Wayland, PipeWire, a Keychron Q1 HE and
Vesktop. To use a different keyboard, change the `[ids]` line in
[`contrib/keyd/default.conf`](contrib/keyd/default.conf). Get the ID by running
`sudo keyd monitor` and pressing a key.

## How it works

```
Caps Lock ──keyd──▶ F24 on "keyd virtual keyboard"
                         │  evdev, read without grabbing
                         ▼
                     ptt-gate ──libpulse──▶ PipeWire: default source mute on/off
                                                  │
                                                  ▼
                                     Vesktop on Voice Activity
```

The key is read from the kernel (evdev), below the compositor, so it doesn't
matter which window has focus. The mic is muted on start, on exit and whenever
the input device disappears, so it is never left open.

## Setup

```sh
make setup            # ./scripts/setup.sh --dry-run shows what it would do first
```

This installs the keyd config, adds you to the `input` group and installs the
daemon as a systemd user service. **Log out and back in** afterwards.

In Vesktop, under **Voice & Video**:

- **Input Mode:** Voice Activity
- **Automatically determine input sensitivity:** off, slider all the way left
- **Noise suppression (Krisp):** off if words still get clipped

Under **Keybinds**, remove any old push-to-talk bind.

## Usage

```
Usage: ptt-gate [options]
  -d, --device NAME   input device to listen on (default: keyd virtual keyboard)
  -k, --key KEY       key to hold: KEY_F24, F24 or a numeric code (default: KEY_F24)
  -s, --source NAME   PulseAudio/PipeWire source (default: @DEFAULT_SOURCE@)
  -v, --verbose       log every press and release
  -h, --help          show this help
  -V, --version       show the version
```

Exit codes: 0 on a clean stop, 1 on a runtime failure, 2 on a usage error.

## Troubleshooting

```sh
make doctor
journalctl --user -u ptt-gate -b
```

- **First word clipped:** this is Discord's voice activity, not the gate. Check
  the Vesktop settings above.
- **`permission denied on /dev/input`:** log out and back in so the `input`
  group applies.
- **keyd remap does nothing:** keyd silently ignores invalid key names. Check
  with `sudo keyd monitor`.

## Development

```sh
make check            # build, tests, ASan/UBSan/valgrind, analysis, hardening (what CI runs)
make live             # run the real daemon briefly under each sanitizer
make help             # every target
```

On CachyOS (znver4) valgrind can't run at all, so the valgrind targets print
SKIPPED there. CI runs them on Ubuntu.

## Uninstall

```sh
make uninstall
```

## License

GPL-3.0, see [LICENSE](LICENSE).
