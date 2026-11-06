#include "ptt.h"

/* cmocka requires these, in this order, before its own header. */
#include <stdarg.h>
#include <stddef.h>
#include <setjmp.h>
#include <stdint.h>

#include <cmocka.h>

static struct input_event
event(unsigned short type, unsigned short code, int value)
{
	struct input_event ev = {0};
	ev.type = type;
	ev.code = code;
	ev.value = value;
	return ev;
}

static enum ptt_action
feed(struct ptt_state *state, unsigned short type, unsigned short code, int value)
{
	struct input_event ev = event(type, code, value);
	return ptt_feed(state, &ev);
}

static void
press_and_release(void **unused)
{
	(void)unused;
	struct ptt_state s;
	ptt_init(&s, KEY_F24);

	assert_int_equal(feed(&s, EV_KEY, KEY_F24, 1), PTT_PRESS);
	assert_int_equal(feed(&s, EV_SYN, SYN_REPORT, 0), PTT_NONE);
	assert_int_equal(feed(&s, EV_KEY, KEY_F24, 0), PTT_RELEASE);
}

static void
autorepeat_is_ignored(void **unused)
{
	(void)unused;
	struct ptt_state s;
	ptt_init(&s, KEY_F24);

	assert_int_equal(feed(&s, EV_KEY, KEY_F24, 2), PTT_NONE);
}

static void
other_keys_and_types_are_ignored(void **unused)
{
	(void)unused;
	struct ptt_state s;
	ptt_init(&s, KEY_F24);

	assert_int_equal(feed(&s, EV_KEY, KEY_A, 1), PTT_NONE);
	assert_int_equal(feed(&s, EV_KEY, KEY_F23, 0), PTT_NONE);
	/* MSC_SCAN shares nothing with the key but the number space. */
	assert_int_equal(feed(&s, EV_MSC, KEY_F24, 1), PTT_NONE);
}

static void
configured_key_is_honoured(void **unused)
{
	(void)unused;
	struct ptt_state s;
	ptt_init(&s, BTN_SIDE);

	assert_int_equal(feed(&s, EV_KEY, KEY_F24, 1), PTT_NONE);
	assert_int_equal(feed(&s, EV_KEY, BTN_SIDE, 1), PTT_PRESS);
}

/* After SYN_DROPPED the evdev protocol says the rest of the packet is junk:
 * even a release of our own key must not be trusted until SYN_REPORT. */
static void
dropped_events_discard_until_report_then_resync(void **unused)
{
	(void)unused;
	struct ptt_state s;
	ptt_init(&s, KEY_F24);

	assert_int_equal(feed(&s, EV_SYN, SYN_DROPPED, 0), PTT_NONE);
	assert_int_equal(feed(&s, EV_KEY, KEY_F24, 0), PTT_NONE);
	assert_int_equal(feed(&s, EV_KEY, KEY_F24, 1), PTT_NONE);
	assert_int_equal(feed(&s, EV_SYN, SYN_REPORT, 0), PTT_RESYNC);

	/* Back to normal afterwards. */
	assert_int_equal(feed(&s, EV_KEY, KEY_F24, 0), PTT_RELEASE);
}

static void
init_clears_dropped_state(void **unused)
{
	(void)unused;
	struct ptt_state s;
	ptt_init(&s, KEY_F24);
	assert_int_equal(feed(&s, EV_SYN, SYN_DROPPED, 0), PTT_NONE);

	ptt_init(&s, KEY_F24); /* a reattached device starts clean */
	assert_int_equal(feed(&s, EV_KEY, KEY_F24, 1), PTT_PRESS);
}

int
main(void)
{
	const struct CMUnitTest tests[] = {
		cmocka_unit_test(press_and_release),
		cmocka_unit_test(autorepeat_is_ignored),
		cmocka_unit_test(other_keys_and_types_are_ignored),
		cmocka_unit_test(configured_key_is_honoured),
		cmocka_unit_test(dropped_events_discard_until_report_then_resync),
		cmocka_unit_test(init_clears_dropped_state),
	};
	return cmocka_run_group_tests_name("ptt", tests, NULL, NULL);
}
