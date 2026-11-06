#ifndef GATE_H
#define GATE_H

#include <pulse/pulseaudio.h>

#include <stdbool.h>

/* The microphone side: one libpulse context (PipeWire serves the same protocol
 * through pipewire-pulse) that mutes and unmutes a single source. Mute
 * requests are fire-and-forget, so a key press never waits on a round trip. */
struct gate
{
	/* Set by the caller before gate_connect. */
	const char *source;
	void (*on_ready)(void *userdata); /* connected; the source has been muted */
	void (*on_lost)(void *userdata);  /* the sound server went away */
	void *userdata;

	/* Private. */
	pa_context *ctx;
	bool talking;
	void (*on_closed)(void *userdata);
};

/* Starts connecting; on_ready fires from the main loop once connected. Returns
 * 0, or -1 when the connection could not even be started. */
int
gate_connect(struct gate *gate, pa_mainloop_api *api);

/* Unmutes while `on` is true. Repeated calls with the same state are free. */
void
gate_set_talking(struct gate *gate, bool on);

bool
gate_is_talking(const struct gate *gate);

/* Mutes the source and calls `done` once the server confirms it, so the
 * program never exits with the microphone open. Calls `done` immediately when
 * there is no connection to mute through. */
void
gate_close(struct gate *gate, void (*done)(void *userdata));

void
gate_free(struct gate *gate);

#endif
