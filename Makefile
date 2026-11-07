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

# Shared by every build -- release, tests, ASan, UBSan, valgrind -- so a warning
# cannot hide in one of them. -Werror is on by default; `make EXTRA_CFLAGS=-Wno-error`
# is the escape hatch for a newer compiler with a new warning.
WARN_CFLAGS := -Wall -Wextra -Werror -Wpedantic -Wshadow -Wvla -Wstrict-prototypes -Wpointer-arith \
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

# --- runtime checkers ----------------------------------------------------------
# One build per checker, under $(BUILD)/<checker>/. Each keeps WARN_CFLAGS but
# drops the hardening flags: FORTIFY interposes the very calls ASan wants to
# see, and -ftrivial-auto-var-init=zero would hide exactly the uninitialised
# reads memcheck looks for. The checkers are separate builds rather than one
# combined one because valgrind cannot run a sanitized binary at all.
CHECKERS := asan ubsan vg

SAN_COMMON   := -fno-omit-frame-pointer -g -O1
asan_CFLAGS  := -fsanitize=address $(SAN_COMMON)
# Without -fno-sanitize-recover UBSan only prints and the run still exits 0.
ubsan_CFLAGS := -fsanitize=undefined -fno-sanitize-recover=all $(SAN_COMMON)
vg_CFLAGS    := -g -O0

# How each checker's binaries are run. Leaks count as errors everywhere; for
# valgrind only definite/indirect ones, as libpulse keeps caches reachable on purpose.
asan_RUN  := env ASAN_OPTIONS=detect_leaks=1:strict_string_checks=1:detect_stack_use_after_return=1
ubsan_RUN := env UBSAN_OPTIONS=print_stacktrace=1
vg_RUN    := valgrind -q --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect \
             --errors-for-leak-kinds=definite,indirect --track-origins=yes

# The daemon itself, against the real input device and sound server, for
# LIVE_SECONDS, then SIGTERM: a clean shutdown must exit 0 under every checker.
LIVE_SECONDS ?= 5

# cmocka is a test-time dependency only and never linked into $(BIN).
CMOCKA_CFLAGS := $(shell pkg-config --cflags cmocka 2>/dev/null)
CMOCKA_LIBS   := $(shell pkg-config --libs cmocka 2>/dev/null || echo -lcmocka)
TEST_CFLAGS   := -Itests $(CMOCKA_CFLAGS)

BUILD := build
BIN   := $(BUILD)/ptt-gate

# One cmocka suite per module, discovered rather than listed.
TESTS     := $(sort $(patsubst tests/test_%.c,%,$(wildcard tests/test_*.c)))
TEST_BINS := $(addprefix $(BUILD)/test_,$(TESTS))

# $(call checker_tests,asan) -> build/asan/test_options build/asan/test_ptt
checker_tests = $(addprefix $(BUILD)/$(1)/test_,$(TESTS))

LIB_SRC := src/ptt.c src/device.c src/gate.c src/options.c
BIN_SRC := src/main.c $(LIB_SRC)
HEADERS := $(wildcard include/*.h)
SCRIPTS := $(wildcard scripts/*.sh)

PREFIX   ?= $(HOME)/.local
UNIT_DIR ?= $(HOME)/.config/systemd/user
DOC_DIR  ?= $(PREFIX)/share/doc/ptt-gate
UNIT     := contrib/systemd/ptt-gate.service

BOLD  := \033[1m
CYAN  := \033[36m
RESET := \033[0m

.DEFAULT_GOAL := help

# --- build and tests ---------------------------------------------------------

##@ Build and test
.PHONY: build
build: $(BIN) ## compile build/ptt-gate

$(BIN): $(BIN_SRC) $(HEADERS) VERSION
	@mkdir -p $(BUILD)
	$(CC) $(ALL_CFLAGS) -o $@ $(BIN_SRC) $(ALL_LDFLAGS) $(LIBS)

$(BUILD)/test_%: tests/test_%.c $(LIB_SRC) $(HEADERS) VERSION
	@mkdir -p $(BUILD)
	$(CC) $(ALL_CFLAGS) $(TEST_CFLAGS) -o $@ $< $(LIB_SRC) $(ALL_LDFLAGS) $(LIBS) $(CMOCKA_LIBS)

# The daemon and test binaries for one checker: build/<checker>/...
define checker_rules
$(BUILD)/$(1)/ptt-gate: $(BIN_SRC) $(HEADERS) VERSION
	@mkdir -p $$(@D)
	$$(CC) $$(BASE_CFLAGS) $$(WARN_CFLAGS) $$($(1)_CFLAGS) $$(EXTRA_CFLAGS) -o $$@ $$(BIN_SRC) $$(LIBS)

$(BUILD)/$(1)/test_%: tests/test_%.c $(LIB_SRC) $(HEADERS) VERSION
	@mkdir -p $$(@D)
	$$(CC) $$(BASE_CFLAGS) $$(WARN_CFLAGS) $$($(1)_CFLAGS) $$(EXTRA_CFLAGS) $$(TEST_CFLAGS) \
		-o $$@ $$< $$(LIB_SRC) $$(LIBS) $$(CMOCKA_LIBS)
endef
$(foreach c,$(CHECKERS),$(eval $(call checker_rules,$(c))))

# Recipe fragments. $(1) is the runner prefix (empty, an env assignment, or
# valgrind), $(2) the binaries.
run-suites = for t in $(2); do $(1) "$$t" || exit 1; done
# The CLI paths the suites cannot reach: main's exit codes.
run-cli = $(1) $(2) --version >/dev/null && $(1) $(2) --help >/dev/null \
	&& { $(1) $(2) --bogus 2>/dev/null; [ $$? -eq 2 ]; } \
	|| { echo "cli: $(2) failed (a usage error must exit 2, --help/--version 0)"; exit 1; }
# --preserve-status: report the daemon's own exit code, not timeout's 124.
run-live = echo "live: $(2) for $(LIVE_SECONDS)s"; \
	timeout --preserve-status -s TERM $(LIVE_SECONDS) $(1) $(2) -v; rc=$$?; \
	[ $$rc -eq 0 ] || { echo "live: $(2) exited $$rc, expected a clean 0"; exit 1; }; \
	echo "live: $(2) shut down cleanly"

.PHONY: test
test: $(TEST_BINS) $(BIN) ## run the cmocka unit suites and CLI checks
	@$(call run-suites,,$(TEST_BINS))
	@$(call run-cli,,$(BIN))

.PHONY: test-asan
test-asan: $(call checker_tests,asan) $(BUILD)/asan/ptt-gate ## the same under AddressSanitizer (+ LeakSanitizer)
	@$(call run-suites,$(asan_RUN),$(call checker_tests,asan))
	@$(call run-cli,$(asan_RUN),$(BUILD)/asan/ptt-gate)

.PHONY: test-ubsan
test-ubsan: $(call checker_tests,ubsan) $(BUILD)/ubsan/ptt-gate ## the same under UndefinedBehaviorSanitizer
	@$(call run-suites,$(ubsan_RUN),$(call checker_tests,ubsan))
	@$(call run-cli,$(ubsan_RUN),$(BUILD)/ubsan/ptt-gate)

# valgrind has to be able to run anything at all first. It decodes no AVX-512,
# so on a system whose glibc is built for it (CachyOS's znver4/v4 repos) every
# dynamic binary dies with SIGILL inside ld.so before main. That is said loudly
# and skipped there, rather than failing every `make check`; CI runs it for real.
vg-usable = command -v valgrind >/dev/null || { echo "$@: valgrind is not installed"; exit 1; }; \
	( ulimit -c 0; valgrind -q /bin/true ) 2>/dev/null || { \
		echo "$@: SKIPPED -- valgrind cannot run any program on this system"; \
		echo "$@: (glibc here uses AVX-512, which valgrind does not support; see 'valgrind /bin/true')"; \
		exit 0; }

.PHONY: test-valgrind
test-valgrind: $(call checker_tests,vg) $(BUILD)/vg/ptt-gate ## the same under valgrind memcheck
	@$(vg-usable); \
	$(call run-suites,$(vg_RUN),$(call checker_tests,vg)); \
	$(call run-cli,$(vg_RUN),$(BUILD)/vg/ptt-gate)

##@ Live (needs the keyd device and a running sound server)
.PHONY: live-asan
live-asan: $(BUILD)/asan/ptt-gate ## run the real daemon briefly under ASan, require a clean exit
	@$(call run-live,$(asan_RUN),$<)

.PHONY: live-ubsan
live-ubsan: $(BUILD)/ubsan/ptt-gate ## the same under UBSan
	@$(call run-live,$(ubsan_RUN),$<)

.PHONY: live-valgrind
live-valgrind: $(BUILD)/vg/ptt-gate ## the same under valgrind
	@$(vg-usable); \
	$(call run-live,$(vg_RUN),$<)

# One after another even under -j: each run owns the real device and mic.
.PHONY: live
live: ## all three
	@$(MAKE) --no-print-directory live-asan
	@$(MAKE) --no-print-directory live-ubsan
	@$(MAKE) --no-print-directory live-valgrind

# The hardening flags are probed and silently dropped by compilers that lack
# them; this is the check that makes a missing one visible.
##@ Checks
.PHONY: hardening-check
hardening-check: $(BIN) ## assert RELRO/NOW/PIE/canary/NX reached the binary
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
analyze: ## -fanalyzer, clang-tidy and shellcheck
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
format: ## clang-format the sources in place
	clang-format -i $(BIN_SRC) $(HEADERS) $(wildcard tests/*.c)

.PHONY: check
check: build test test-asan test-ubsan test-valgrind analyze hardening-check ## everything above except live (what CI runs)

# --- install and system setup -----------------------------------------------

##@ Install
.PHONY: install
install: $(BIN) ## install the daemon and its user unit, restart it
	install -Dm755 $(BIN) $(PREFIX)/bin/ptt-gate
	install -Dm644 $(UNIT) $(UNIT_DIR)/ptt-gate.service
	install -Dm644 README.md $(DOC_DIR)/README.md
	install -Dm644 LICENSE $(DOC_DIR)/LICENSE
	systemctl --user daemon-reload
	systemctl --user enable ptt-gate
	systemctl --user restart ptt-gate

.PHONY: uninstall
uninstall: ## remove the daemon and its user unit
	-systemctl --user disable --now ptt-gate
	rm -f $(PREFIX)/bin/ptt-gate $(UNIT_DIR)/ptt-gate.service
	rm -rf $(DOC_DIR)
	systemctl --user daemon-reload
	@echo "Left in place (system-wide, shared with other tools):"
	@echo "  /etc/keyd/default.conf    restore the .bak next to it, then: sudo keyd reload"
	@echo "  input group membership    sudo gpasswd -d $$USER input, then log out and in"

.PHONY: setup
setup: ## full system setup: keyd, input group, daemon (asks for sudo)
	@./scripts/setup.sh

.PHONY: doctor
doctor: ## check every piece push-to-talk depends on
	@./scripts/doctor.sh

# Source tarball of the committed tree (uncommitted changes are not included).
DIST := tools.ptt-gate-$(VERSION)

##@ Release
.PHONY: dist
dist: ## source tarball of HEAD, plus its sha256
	@mkdir -p $(BUILD)
	git archive --prefix=$(DIST)/ -o $(BUILD)/$(DIST).tar.gz HEAD
	cd $(BUILD) && sha256sum $(DIST).tar.gz > $(DIST).tar.gz.sha256
	@echo "$(BUILD)/$(DIST).tar.gz"

.PHONY: clean
clean: ## remove build/
	@rm -rf $(BUILD)

##@ Help

.PHONY: help
help: ## show this menu
	@awk 'BEGIN {FS = ":.*##"; printf "\n$(BOLD)ptt-gate $(VERSION)$(RESET)\n"} \
	      /^[a-zA-Z_.-]+:.*?##/ { printf "  $(CYAN)%-18s$(RESET) %s\n", $$1, $$2 } \
	      /^##@/ { printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@printf "\n"
