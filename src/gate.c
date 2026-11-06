#include "gate.h"

#include <stddef.h>
#include <stdio.h>

static void
log_failure(pa_context *ctx, int success, const struct gate *gate)
{
	if (success == 0)
	{
		(void)fprintf(stderr, "cannot set mute on %s: %s\n", gate->source, pa_strerror(pa_context_errno(ctx)));
	}
}

static void
on_mute_done(pa_context *ctx, int success, void *userdata)
{
	log_failure(ctx, success, userdata);
}

static void
on_close_done(pa_context *ctx, int success, void *userdata)
{
	struct gate *gate = userdata;
	log_failure(ctx, success, gate);
	gate->on_closed(gate->userdata);
}

static void
send_mute(struct gate *gate, bool mute, pa_context_success_cb_t done)
{
	pa_operation *op = pa_context_set_source_mute_by_name(gate->ctx, gate->source, mute, done, gate);
	if (op != NULL)
	{
		pa_operation_unref(op);
	}
	else
	{
		done(gate->ctx, 0, gate);
	}
}

static void
on_state(pa_context *ctx, void *userdata)
{
	struct gate *gate = userdata;

	switch (pa_context_get_state(ctx))
	{
	case PA_CONTEXT_READY:
		gate->talking = false;
		send_mute(gate, true, on_mute_done);
		gate->on_ready(gate->userdata);
		break;
	case PA_CONTEXT_FAILED:
	case PA_CONTEXT_TERMINATED:
		(void)fprintf(stderr, "sound server lost: %s\n", pa_strerror(pa_context_errno(ctx)));
		gate->on_lost(gate->userdata);
		break;
	default:
		break;
	}
}

int
gate_connect(struct gate *gate, pa_mainloop_api *api)
{
	gate->ctx = pa_context_new(api, "ptt-gate");
	if (gate->ctx == NULL)
	{
		(void)fprintf(stderr, "cannot create sound server context\n");
		return -1;
	}
	pa_context_set_state_callback(gate->ctx, on_state, gate);
	/* NOFAIL: if the server is not up yet (early in the session), wait for it
	 * rather than failing straight away. */
	if (pa_context_connect(gate->ctx, NULL, PA_CONTEXT_NOFAIL, NULL) < 0)
	{
		(void)fprintf(stderr, "cannot connect to sound server: %s\n", pa_strerror(pa_context_errno(gate->ctx)));
		return -1;
	}
	return 0;
}

static bool
is_ready(const struct gate *gate)
{
	return gate->ctx != NULL && pa_context_get_state(gate->ctx) == PA_CONTEXT_READY;
}

void
gate_set_talking(struct gate *gate, bool on)
{
	if (on == gate->talking || !is_ready(gate))
	{
		return;
	}
	gate->talking = on;
	send_mute(gate, !on, on_mute_done);
}

bool
gate_is_talking(const struct gate *gate)
{
	return gate->talking;
}

void
gate_close(struct gate *gate, void (*done)(void *userdata))
{
	gate->talking = false;
	if (!is_ready(gate))
	{
		done(gate->userdata);
		return;
	}
	gate->on_closed = done;
	send_mute(gate, true, on_close_done);
}

void
gate_free(struct gate *gate)
{
	if (gate->ctx == NULL)
	{
		return;
	}
	/* Detach the callback first: disconnecting reports TERMINATED, which is not
	 * a loss of the server at this point. */
	pa_context_set_state_callback(gate->ctx, NULL, NULL);
	pa_context_disconnect(gate->ctx);
	pa_context_unref(gate->ctx);
	gate->ctx = NULL;
}
