#ifndef PTT_H
#define PTT_H

#include <linux/input.h>

#include <stdbool.h>

/* What the caller should do after feeding one input event. */
enum ptt_action
{
	PTT_NONE,	 /* nothing changed */
	PTT_PRESS,	 /* the push-to-talk key went down */
	PTT_RELEASE, /* the push-to-talk key went up */
	PTT_RESYNC,	 /* events were lost: re-read the key's real state from the device */
};

/* The key state machine, kept free of I/O so it can be tested without a device.
 * After SYN_DROPPED the kernel's buffer overflowed and the current packet is
 * incomplete; everything up to the next SYN_REPORT is discarded, as the evdev
 * protocol requires, and the caller is then told to resync. */
struct ptt_state
{
	unsigned short key;
	bool dropped;
};

void
ptt_init(struct ptt_state *state, unsigned short key);

/* Autorepeat (value 2) and every other key are ignored. */
enum ptt_action
ptt_feed(struct ptt_state *state, const struct input_event *ev);

#endif
