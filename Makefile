# Project entry point: build, tests, analysis, install, and system setup.

VERSION := $(shell cat VERSION)

CC := cc

# $(call ...) splits its arguments on commas, and every -Wl, flag contains them.
comma := ,

# Returns $(1) if the compiler accepts it, else nothing, so an older cc still
# builds and just gets fewer hardening flags. `hardening-check` is what notices
# when one went missing.
cc-option = $(shell $(CC) $(1) -Werror -x c -c /dev/null -o /dev/null 2>/dev/null && echo $(1))
# -z options are consumed by the linker, so the probe has to link a real program.
ld-option = $(shell printf 'int main(void){return 0;}' \
	| $(CC) $(1) -x c - -o /dev/null 2>/dev/null && echo $(1))

# Required flags are kept apart from CFLAGS, which is only the optimisation
# level: `CFLAGS=-O3 make` and `make EXTRA_CFLAGS=-Werror` both still build.
# Everything used is POSIX.1-2008 (openat, dirfd, O_CLOEXEC, open_memstream).
BASE_CFLAGS := -std=c17 -Iinclude -D_POSIX_C_SOURCE=200809L -DPTT_GATE_VERSION='"$(VERSION)"' \
               $(shell pkg-config --cflags libpulse)

# Shared by the release and sanitizer builds, so a warning cannot hide in one.
WARN_CFLAGS := -Wall -Wextra -Wpedantic -Wshadow -Wvla -Wstrict-prototypes -Wpointer-arith \
               -Wwrite-strings -Wconversion -Wsign-conversion -Wformat -Wformat-security \
               -Wcast-qual -Wmissing-prototypes -Wundef

# -U first: some distro compilers predefine _FORTIFY_SOURCE and warn on redefinition.
HARDEN_CFLAGS := -fstack-protector-strong -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -fPIE \
                 $(call cc-option,-ftrivial-auto-var-init=zero) \
                 $(call cc-option,-fcf-protection=full) \
                 $(call cc-option,-fstack-clash-protection)
HARDEN_LDFLAGS := -pie $(call ld-option,-Wl$(comma)-z$(comma)relro$(comma)-z$(comma)now) \
                       $(call ld-option,-Wl$(comma)-z$(comma)noexecstack)

CFLAGS       ?= -O2
EXTRA_CFLAGS ?=
LDFLAGS      ?=
LIBS         := $(shell pkg-config --libs libpulse)
ALL_CFLAGS    = $(BASE_CFLAGS) $(WARN_CFLAGS) $(HARDEN_CFLAGS) $(CFLAGS) $(EXTRA_CFLAGS)
ALL_LDFLAGS   = $(HARDEN_LDFLAGS) $(LDFLAGS)

# FORTIFY and the other hardening flags are dropped: the sanitizers are the
# check in this build, and FORTIFY interposes the very calls ASan wants to see.
ASAN_CFLAGS := -fsanitize=address,undefined -fno-omit-frame-pointer -g -O1
ASAN_FLAGS   = $(BASE_CFLAGS) $(WARN_CFLAGS) $(ASAN_CFLAGS) $(EXTRA_CFLAGS)
# Without halt_on_error UBSan only prints and the run still exits 0.
ASAN_ENV := ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1

# cmocka is a test-time dependency only and never linked into $(BIN).
CMOCKA_CFLAGS := $(shell pkg-config --cflags cmocka 2>/dev/null)
CMOCKA_LIBS   := $(shell pkg-config --libs cmocka 2>/dev/null || echo -lcmocka)
TEST_CFLAGS   := -Itests $(CMOCKA_CFLAGS)

BUILD    := build
BIN      := $(BUILD)/ptt-gate
ASAN_BIN := $(BUILD)/asan_ptt-gate

# One cmocka suite per module, discovered rather than listed.
TESTS      := $(sort $(patsubst tests/test_%.c,%,$(wildcard tests/test_*.c)))
TEST_BINS  := $(addprefix $(BUILD)/test_,$(TESTS))
ASAN_TESTS := $(addprefix $(BUILD)/asan_test_,$(TESTS))

LIB_SRC := src/ptt.c src/device.c src/gate.c src/options.c
BIN_SRC := src/main.c $(LIB_SRC)
HEADERS := $(wildcard include/*.h)
SCRIPTS := $(wildcard scripts/*.sh)

PREFIX   ?= $(HOME)/.local
UNIT_DIR ?= $(HOME)/.config/systemd/user
UNIT     := contrib/systemd/ptt-gate.service

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Build:"
	@echo "  build            compile $(BIN)"
	@echo "  test             run the cmocka unit suites"
	@echo "  test-asan        re-run the suites under ASan/UBSan"
	@echo "  analyze          -fanalyzer, clang-tidy and shellcheck"
	@echo "  hardening-check  assert RELRO/NOW/PIE/canary/NX reached $(BIN)"
	@echo "  format           clang-format the sources in place"
	@echo "  check            all of the above (what CI runs)"
	@echo ""
	@echo "Install:"
	@echo "  setup            full system setup: keyd, input group, daemon (asks for sudo)"
	@echo "  install          install the daemon and its user unit, restart it"
	@echo "  uninstall        remove the daemon and its user unit"
	@echo "  doctor           check every piece push-to-talk depends on"
	@echo ""
	@echo "  clean            remove $(BUILD)"

# --- build and tests ---------------------------------------------------------

.PHONY: build
build: $(BIN)

$(BIN): $(BIN_SRC) $(HEADERS) VERSION
	@mkdir -p $(BUILD)
	$(CC) $(ALL_CFLAGS) -o $@ $(BIN_SRC) $(ALL_LDFLAGS) $(LIBS)

$(ASAN_BIN): $(BIN_SRC) $(HEADERS) VERSION
	@mkdir -p $(BUILD)
	$(CC) $(ASAN_FLAGS) -o $@ $(BIN_SRC) $(LIBS)

$(BUILD)/test_%: tests/test_%.c $(LIB_SRC) $(HEADERS) VERSION
	@mkdir -p $(BUILD)
	$(CC) $(ALL_CFLAGS) $(TEST_CFLAGS) -o $@ $< $(LIB_SRC) $(ALL_LDFLAGS) $(LIBS) $(CMOCKA_LIBS)

$(BUILD)/asan_test_%: tests/test_%.c $(LIB_SRC) $(HEADERS) VERSION
	@mkdir -p $(BUILD)
	$(CC) $(ASAN_FLAGS) $(TEST_CFLAGS) -o $@ $< $(LIB_SRC) $(LIBS) $(CMOCKA_LIBS)

.PHONY: test
test: $(TEST_BINS) $(BIN)
	@for t in $(TEST_BINS); do "$$t" || exit 1; done
	@$(BIN) --version >/dev/null
	@$(BIN) --bogus 2>/dev/null; [ $$? -eq 2 ] || { echo "test: expected exit 2 on a usage error"; exit 1; }

.PHONY: test-asan
test-asan: $(ASAN_TESTS) $(ASAN_BIN)
	@for t in $(ASAN_TESTS); do $(ASAN_ENV) "$$t" || exit 1; done
	@$(ASAN_ENV) $(ASAN_BIN) --help >/dev/null

# The hardening flags are probed and silently dropped by compilers that lack
# them; this is the check that makes a missing one visible.
.PHONY: hardening-check
hardening-check: $(BIN)
	@fail=0; \
	want() { \
		if readelf $$2 -W $(BIN) 2>/dev/null | grep -qE -- "$$3"; then echo "  ok    $$1"; \
		else echo "  FAIL  $$1"; fail=1; fi; \
	}; \
	deny() { \
		if readelf $$2 -W $(BIN) 2>/dev/null | grep -qE -- "$$3"; then echo "  FAIL  $$1"; fail=1; \
		else echo "  ok    $$1"; fi; \
	}; \
	echo "hardening-check: $(BIN)"; \
	want "RELRO"            -l 'GNU_RELRO'; \
	want "BIND_NOW"         -d 'BIND_NOW|FLAGS_1.*NOW'; \
	want "PIE"              -d 'FLAGS_1.*PIE'; \
	want "stack canary"     -s '__stack_chk_fail'; \
	want "FORTIFY_SOURCE"   -s '_chk@'; \
	deny "executable stack" -l 'GNU_STACK.*RWE'; \
	[ $$fail -eq 0 ] || { echo "hardening-check: the binary is missing hardening it should have"; exit 1; }

.PHONY: analyze
analyze:
	@echo "analyze: $(CC) -fanalyzer"
	@for f in $(BIN_SRC); do \
		$(CC) $(ALL_CFLAGS) $(call cc-option,-fanalyzer) -Werror -c -o /dev/null "$$f" || exit 1; \
	done
	@if command -v clang-tidy >/dev/null 2>&1; then \
		echo "analyze: clang-tidy"; \
		clang-tidy --quiet $(BIN_SRC) -- $(BASE_CFLAGS) || exit 1; \
	else \
		echo "analyze: clang-tidy not installed, skipped"; \
	fi
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "analyze: shellcheck"; \
		shellcheck $(SCRIPTS) || exit 1; \
	else \
		echo "analyze: shellcheck not installed, skipped"; \
	fi

.PHONY: format
format:
	clang-format -i $(BIN_SRC) $(HEADERS) $(wildcard tests/*.c)

.PHONY: check
check: build test test-asan analyze hardening-check

# --- install and system setup -----------------------------------------------

.PHONY: install
install: $(BIN)
	install -Dm755 $(BIN) $(PREFIX)/bin/ptt-gate
	install -Dm644 $(UNIT) $(UNIT_DIR)/ptt-gate.service
	systemctl --user daemon-reload
	systemctl --user enable ptt-gate
	systemctl --user restart ptt-gate

.PHONY: uninstall
uninstall:
	-systemctl --user disable --now ptt-gate
	rm -f $(PREFIX)/bin/ptt-gate $(UNIT_DIR)/ptt-gate.service
	systemctl --user daemon-reload
	@echo "Left in place (system-wide, shared with other tools):"
	@echo "  /etc/keyd/default.conf    restore the .bak next to it, then: sudo keyd reload"
	@echo "  input group membership    sudo gpasswd -d $$USER input, then log out and in"

.PHONY: setup
setup:
	@./scripts/setup.sh

.PHONY: doctor
doctor:
	@./scripts/doctor.sh

.PHONY: clean
clean:
	@rm -rf $(BUILD)
