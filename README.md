# tools.ptt-gate

> The installed command, systemd unit and log name are all `ptt-gate`.

Push-to-talk that works on KDE Plasma Wayland, including while a Proton game
(WoW) has focus, by gating the microphone itself instead of asking Discord to
see a key.

Hold Caps Lock: the mic is live. Let go: it is muted. Discord (Vesktop) runs on
Voice Activity and simply never hears anything while the mic is muted.

## Why

Discord's push-to-talk needs to see global key state. Under Wayland a
background app is not allowed to, and with an XWayland/Proton window focused
even KWin's `XwaylandEavesdrops=All` does not get the key through to Vesktop
reliably. No Discord-side keybind fixes that.

`ptt-gate` reads the key from the kernel (evdev), below the compositor, so
focus is irrelevant, and toggles the PipeWire source mute directly.

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

- **keyd** remaps Caps Lock to F24 on the Keychron only. F24 is bound to
  nothing, so holding it in a game never turns other keys into Ctrl+key combos,
  and unlike Caps Lock it is not a locking key.
- **ptt-gate** is a single-threaded C daemon on one libpulse main loop: the
  input fd, signals, the device retry timer and the sound server connection.
  Mute requests are fire-and-forget, so a key press never waits on a round trip.
  It mutes on start, on exit and whenever the input device disappears, so the
  mic is never left open. If keyd restarts it re-finds the device; if the sound
  server restarts it exits non-zero and systemd brings it back.

## Setup

```sh
make setup            # or: ./scripts/setup.sh --dry-run  to see what it would do
```

`setup` is idempotent and only changes what is missing; steps needing root go
through sudo, so run it in a terminal. It:

1. checks that `keyd`, a C compiler, `pkg-config` and `libpulse` are installed
   (it prints the `pacman` line rather than installing anything),
2. installs [`contrib/keyd/default.conf`](contrib/keyd/default.conf) to
   `/etc/keyd/default.conf` (backing up the old one to `.bak`) and enables keyd,
3. adds you to the `input` group so the daemon can read `/dev/input`.
   **Log out and back in** afterwards,
4. builds and installs the daemon to `~/.local/bin/ptt-gate` with its systemd
   user unit, and starts it.

For a different keyboard, change the ID under `[ids]` in the keyd config. Run
`sudo keyd monitor`, press a key, and copy the ID printed beside it.

### Vesktop settings

These can't be scripted, so set them once by hand. In **Voice & Video**:

- **Input Mode:** Voice Activity.
- **Automatically determine input sensitivity:** off, with the slider **all the
  way left**. The mute is the gate now; Discord's own voice detection only adds
  delay and clips the first syllable.
- **Noise suppression (Krisp):** turn it off if words still get clipped. It
  buffers audio too.

Under **Keybinds**, remove any old push-to-talk bind.

## Troubleshooting

```sh
make doctor           # checks keyd, the device, permissions, the daemon and the mic
journalctl --user -u ptt-gate -b
```

- **The first word is clipped / it lags.** This is almost always Discord's
  voice activity, not the gate: see [Vesktop settings](#vesktop-settings). To
  watch the gate on its own, hold Caps Lock while running
  `while :; do wpctl get-volume @DEFAULT_AUDIO_SOURCE@; sleep 0.05; done`.
- **`permission denied on /dev/input`.** You were added to `input` but this
  login predates it. Log out and back in.
- **The keyd remap does nothing.** keyd silently ignores invalid key names
  (`rightctrl` is wrong, `rightcontrol` is right). Check with `sudo keyd monitor`.

## Usage

The defaults match the setup above; the options are for other keys and devices.

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

## Development

Everything runs through the Makefile (`make help` lists it all). Every build
uses `-Wall -Wextra -Werror` and the rest of `WARN_CFLAGS`.

```sh
make build            # build/ptt-gate, hardened (-O2, FORTIFY, PIE, RELRO, canary)
make test             # cmocka unit suites + CLI exit-code checks
make test-asan        # the same under AddressSanitizer + LeakSanitizer
make test-ubsan       # the same under UndefinedBehaviorSanitizer (aborts on the first finding)
make test-valgrind    # the same under valgrind memcheck
make analyze          # gcc -fanalyzer, clang-tidy, shellcheck
make hardening-check  # assert the hardening reached the binary
make check            # all of the above: what CI runs
make live             # the real daemon for 5s under ASan, UBSan and valgrind, then SIGTERM
make format
```

Each checker gets its own build under `build/<checker>/`, without the
hardening flags. FORTIFY gets in the sanitizers' way, and
`-ftrivial-auto-var-init` would hide the uninitialised reads valgrind looks for.
`make live` needs the keyd device and a running sound server, so it isn't part
of `check`. It runs alongside the installed service without disturbing it.

**valgrind on CachyOS:** the `znver4` repos build glibc with AVX-512, which
valgrind can't decode, so every program dies with SIGILL in `ld.so` before
`main` (try `valgrind /bin/true`). The valgrind targets detect this and print
SKIPPED instead of failing. CI runs them for real on Ubuntu.

The key handling, including the evdev `SYN_DROPPED` resync, is a pure state
machine in [`src/ptt.c`](src/ptt.c), tested without a device or a sound server.
cmocka is a test-only dependency.

## Uninstall

```sh
make uninstall
```

This removes the daemon and its unit. The keyd config and the `input` group
membership are left in place, and the command prints how to undo them.

To go back to the original Python version: restore `~/.local/bin/ptt-gate.py.bak`
and `~/.config/systemd/user/ptt-gate.service.bak`, then run
`systemctl --user daemon-reload && systemctl --user restart ptt-gate`.

## License

GPL-3.0, see [LICENSE](LICENSE).
