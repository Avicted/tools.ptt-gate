#include "ptt.h"

void
ptt_init(struct ptt_state *state, unsigned short key)
{
	state->key = key;
	state->dropped = false;
}

enum ptt_action
ptt_feed(struct ptt_state *state, const struct input_event *ev)
{
	if (ev->type == EV_SYN && ev->code == SYN_DROPPED)
	{
		state->dropped = true;
		return PTT_NONE;
	}
	if (state->dropped)
	{
		if (ev->type == EV_SYN && ev->code == SYN_REPORT)
		{
			state->dropped = false;
			return PTT_RESYNC;
		}
		return PTT_NONE;
	}
	if (ev->type != EV_KEY || ev->code != state->key)
	{
		return PTT_NONE;
	}
	switch (ev->value)
	{
	case 1:
		return PTT_PRESS;
	case 0:
		return PTT_RELEASE;
	default: /* 2 = autorepeat */
		return PTT_NONE;
	}
}
