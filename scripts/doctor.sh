#!/usr/bin/env bash
# Checks every piece push-to-talk depends on, read-only, and says how to fix
# whatever is broken. Run it first whenever push-to-talk misbehaves.
set -uo pipefail

cd "$(dirname "$0")/.."

KEYD_CONF=/etc/keyd/default.conf
DEVICE="keyd virtual keyboard"
KEY_F24=194

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() {
	printf '  FAIL  %s\n        fix: %s\n' "$1" "$2"
	failures=$((failures + 1))
}
warn() { printf '  warn  %s\n        %s\n' "$1" "$2"; }

echo "keyd"
if systemctl is-active --quiet keyd; then
	pass "keyd is running"
else
	fail "keyd is not running" "sudo systemctl enable --now keyd"
fi
if grep -qE '^[[:space:]]*capslock[[:space:]]*=[[:space:]]*f24' "$KEYD_CONF" 2>/dev/null; then
	pass "$KEYD_CONF maps capslock to f24"
else
	fail "$KEYD_CONF does not map capslock to f24" "make setup"
fi

# /proc/bus/input/devices lists each device as a block; the KEY= bitmap is a
# run of hex words, most significant first, one per long.
key_bitmap=$(awk -v name="$DEVICE" '
	/^N: Name=/ { found = ($0 == "N: Name=\"" name "\"") }
	found && /^B: KEY=/ { sub(/^B: KEY=/, ""); print; exit }
' /proc/bus/input/devices)
if [ -z "$key_bitmap" ]; then
	fail "no \"$DEVICE\" input device" "check keyd: sudo journalctl -u keyd -b"
else
	read -ra words <<<"$key_bitmap"
	index=$((${#words[@]} - 1 - KEY_F24 / 64))
	if [ "$index" -ge 0 ] && (((0x${words[index]} >> (KEY_F24 % 64)) & 1)); then
		pass "\"$DEVICE\" exists and can emit F24"
	else
		fail "\"$DEVICE\" cannot emit F24" "sudo systemctl restart keyd"
	fi
fi

echo "permissions"
if id -nG | grep -qw input; then
	pass "this login is in the input group"
elif id -nG "$USER" | grep -qw input; then
	fail "added to the input group, but this login predates it" "log out and back in"
else
	fail "$USER is not in the input group" "sudo usermod -aG input $USER, then log out and in"
fi

echo "daemon"
if systemctl --user is-active --quiet ptt-gate; then
	pid=$(systemctl --user show -p MainPID --value ptt-gate)
	exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
	if [ "$exe" = "$HOME/.local/bin/ptt-gate" ]; then
		pass "ptt-gate is running ($exe)"
	else
		fail "ptt-gate service runs $exe, not the C daemon" "make install"
	fi
	invocation=$(systemctl --user show -p InvocationID --value ptt-gate)
	last=$(journalctl --user -q -o cat _SYSTEMD_INVOCATION_ID="$invocation" 2>/dev/null |
		grep -E 'listening on|input device lost|waiting for|permission denied' | tail -n 1)
	case "$last" in
	"listening on"*) pass "daemon is ${last}" ;;
	"permission denied"*) fail "daemon: $last" "log out and back in, then: systemctl --user restart ptt-gate" ;;
	"") fail "daemon has not found the input device" "journalctl --user -u ptt-gate -b" ;;
	*) fail "daemon: $last" "journalctl --user -u ptt-gate -b" ;;
	esac
else
	fail "ptt-gate service is not running" "make install, then: journalctl --user -u ptt-gate -b"
fi
if pgrep -f 'ptt-gate\.py' >/dev/null; then
	fail "the old Python ptt-gate.py is still running" "pkill -f ptt-gate.py"
fi

echo "microphone"
if source=$(pactl get-default-source 2>/dev/null) && [ -n "$source" ]; then
	pass "default source: $source"
	if pactl get-source-mute @DEFAULT_SOURCE@ | grep -q 'yes'; then
		pass "muted while the key is up"
	else
		warn "default source is live" "expected only while Caps Lock is held; if not, check the daemon above"
	fi
else
	fail "no default capture source" "pick a microphone in the system sound settings"
fi

echo
if [ "$failures" -eq 0 ]; then
	echo "All checks passed. If speech is still clipped, see 'Vesktop settings' in README.md."
else
	echo "$failures check(s) failed."
	exit 1
fi
