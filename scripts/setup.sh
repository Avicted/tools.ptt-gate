#!/usr/bin/env bash
# Sets up everything push-to-talk needs on this machine:
#
#   1. build dependencies (checked, never installed for you)
#   2. keyd: Caps Lock -> F24 on the configured keyboard      (sudo)
#   3. the user in the `input` group, to read /dev/input      (sudo, re-login)
#   4. the ptt-gate daemon and its systemd user unit
#
# Idempotent: every step checks first and only changes what is missing, so it
# is safe to re-run. Steps that need root go through sudo, so run it from a
# terminal. --dry-run shows what would change without changing anything.
set -euo pipefail

cd "$(dirname "$0")/.."

KEYD_CONF=/etc/keyd/default.conf
REPO_CONF=contrib/keyd/default.conf
UNIT_DIR="$HOME/.config/systemd/user"
BIN_DIR="$HOME/.local/bin"

dry_run=0
case "${1:-}" in
--dry-run | -n) dry_run=1 ;;
"") ;;
-h | --help)
	sed -n '2,12s/^# \{0,1\}//p' "$0"
	exit 0
	;;
*)
	echo "usage: $0 [--dry-run]" >&2
	exit 2
	;;
esac

changes=0
relogin=0

step() { printf '\n==> %s\n' "$1"; }
ok() { printf '    ok: %s\n' "$1"; }

# Runs a command that changes the system, or only prints it in a dry run.
change() {
	changes=$((changes + 1))
	if [ "$dry_run" -eq 1 ]; then
		printf '    would run: %s\n' "$*"
	else
		printf '    + %s\n' "$*"
		"$@"
	fi
}

# The keyd config without comments and blank lines: the repo copy is annotated,
# and a comment-only difference is not worth a sudo prompt.
keyd_rules() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }

step "Dependencies"
missing=()
command -v keyd >/dev/null || missing+=(keyd)
command -v cc >/dev/null || missing+=(gcc)
command -v pkg-config >/dev/null || missing+=(pkgconf)
pkg-config --exists libpulse 2>/dev/null || missing+=(libpulse)
if [ "${#missing[@]}" -gt 0 ]; then
	echo "    missing: ${missing[*]}"
	echo "    install them with: sudo pacman -S --needed ${missing[*]}"
	exit 1
fi
ok "keyd, cc, pkg-config, libpulse"

step "keyd: Caps Lock -> F24 ($KEYD_CONF)"
if [ -f "$KEYD_CONF" ] && diff -q <(keyd_rules "$REPO_CONF") <(keyd_rules "$KEYD_CONF") >/dev/null; then
	ok "config already matches $REPO_CONF"
else
	if [ -f "$KEYD_CONF" ]; then
		diff -u "$KEYD_CONF" "$REPO_CONF" | sed 's/^/    /' || true
		change sudo cp -p "$KEYD_CONF" "$KEYD_CONF.bak"
	fi
	change sudo install -Dm644 "$REPO_CONF" "$KEYD_CONF"
	if systemctl is-active --quiet keyd; then
		change sudo keyd reload
	fi
fi
if systemctl is-enabled --quiet keyd && systemctl is-active --quiet keyd; then
	ok "keyd enabled and running"
else
	change sudo systemctl enable --now keyd
fi

step "input group (read access to /dev/input)"
if id -nG "$USER" | grep -qw input; then
	ok "$USER is in the input group"
	# Group changes reach a process only through a new login.
	if ! id -nG | grep -qw input; then
		echo "    note: this login predates it -- log out and back in"
		relogin=1
	fi
else
	change sudo usermod -aG input "$USER"
	relogin=1
fi

step "ptt-gate daemon"
make -s build
if cmp -s build/ptt-gate "$BIN_DIR/ptt-gate" &&
	cmp -s contrib/systemd/ptt-gate.service "$UNIT_DIR/ptt-gate.service" &&
	systemctl --user is-enabled --quiet ptt-gate &&
	systemctl --user is-active --quiet ptt-gate; then
	ok "installed, enabled and running"
else
	change make -s install
fi

echo
if [ "$dry_run" -eq 1 ]; then
	echo "Dry run: $changes change(s) would be made."
elif [ "$changes" -eq 0 ]; then
	echo "Nothing to change: the system is already set up."
else
	echo "Done: $changes change(s) made."
fi
if [ "$relogin" -eq 1 ]; then
	echo "Log out and back in (or reboot) so the daemon can read /dev/input."
fi
cat <<'EOF'

Vesktop/Discord, once (it cannot be scripted):
  Voice & Video -> Input Mode: Voice Activity
  "Automatically determine input sensitivity": off, slider all the way left
  Keybinds: remove any old push-to-talk bind

Then check everything with: make doctor
EOF
