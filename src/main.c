/* ptt-gate: push-to-talk as a microphone gate.
 *
 * While the push-to-talk key is held, the microphone is unmuted; otherwise it
 * is muted. The key is read from evdev, so it works no matter which Wayland or
 * XWayland window has focus, and the voice app just runs on voice activity.
 *
 * Everything runs on one libpulse main loop: the input fd, SIGINT/SIGTERM, the
 * device retry timer and the sound server connection. No threads, no polling. */
#include "device.h"
#include "gate.h"
#include "options.h"
#include "ptt.h"

#include <errno.h>
#include <pulse/mainloop-signal.h>
#include <pulse/pulseaudio.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

#define RETRY_USEC (2 * PA_USEC_PER_SEC)

struct app
{
	struct options opts;
	pa_mainloop_api *api;
	struct gate gate;
	struct ptt_state ptt;
	int fd;
	pa_io_event *io;
	pa_time_event *retry;
	bool waiting_logged; /* "waiting for device" printed since the last attach */
	bool quitting;
	int exit_code;
};

static void
attach_device(struct app *app);

static void
set_talking(struct app *app, bool on)
{
	if (app->opts.verbose && on != gate_is_talking(&app->gate))
	{
		(void)fprintf(stderr, "%s\n", on ? "talk" : "mute");
	}
	gate_set_talking(&app->gate, on);
}

/* --- input device ------------------------------------------------------- */

static void
detach_device(struct app *app)
{
	if (app->io != NULL)
	{
		app->api->io_free(app->io);
		app->io = NULL;
	}
	if (app->fd >= 0)
	{
		close(app->fd);
		app->fd = -1;
	}
}

static void
cancel_retry(struct app *app)
{
	if (app->retry != NULL)
	{
		app->api->time_free(app->retry);
		app->retry = NULL;
	}
}

static void
on_retry(pa_mainloop_api *api, pa_time_event *event, const struct timeval *tv, void *userdata)
{
	(void)tv;
	struct app *app = userdata;
	api->time_free(event);
	app->retry = NULL;
	attach_device(app);
}

static void
schedule_retry(struct app *app)
{
	struct timeval tv;
	pa_timeval_add(pa_gettimeofday(&tv), RETRY_USEC);
	app->retry = app->api->time_new(app->api, &tv, on_retry, app);
}

static void
handle_event(struct app *app, const struct input_event *ev)
{
	switch (ptt_feed(&app->ptt, ev))
	{
	case PTT_PRESS:
		set_talking(app, true);
		break;
	case PTT_RELEASE:
		set_talking(app, false);
		break;
	case PTT_RESYNC:
		set_talking(app, device_key_down(app->fd, app->opts.key));
		break;
	case PTT_NONE:
		break;
	}
}

static void
on_input(pa_mainloop_api *api, pa_io_event *event, int fd, pa_io_event_flags_t flags, void *userdata)
{
	(void)api;
	(void)event;
	struct app *app = userdata;
	struct input_event ev[64];
	ssize_t n;

	while ((n = read(fd, ev, sizeof ev)) > 0)
	{
		size_t count = (size_t)n / sizeof ev[0];
		for (size_t i = 0; i < count; i++)
		{
			handle_event(app, &ev[i]);
		}
	}

	/* libpulse's flags are a plain enum, hence signed: test them as unsigned. */
	unsigned int broken = (unsigned int)PA_IO_EVENT_HANGUP | (unsigned int)PA_IO_EVENT_ERROR;
	bool failed = n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR);
	if (failed || ((unsigned int)flags & broken) != 0U)
	{
		/* Typically keyd restarting, which recreates its virtual keyboard. */
		(void)fprintf(stderr, "input device lost, retrying\n");
		detach_device(app);
		set_talking(app, false);
		schedule_retry(app);
	}
}

static void
attach_device(struct app *app)
{
	if (app->quitting)
	{
		return;
	}

	char path[64];
	app->fd = device_open(app->opts.device, app->opts.key, path, sizeof path);
	if (app->fd < 0)
	{
		if (!app->waiting_logged)
		{
			if (errno == EACCES)
			{
				(void)fprintf(stderr, "permission denied on /dev/input: is the user in the input group?\n");
			}
			else
			{
				(void)fprintf(stderr, "waiting for input device \"%s\"\n", app->opts.device);
			}
			app->waiting_logged = true;
		}
		schedule_retry(app);
		return;
	}

	app->waiting_logged = false;
	(void)fprintf(stderr, "listening on %s (%s)\n", path, app->opts.device);
	ptt_init(&app->ptt, app->opts.key);
	app->io = app->api->io_new(app->api, app->fd, PA_IO_EVENT_INPUT, on_input, app);
	set_talking(app, device_key_down(app->fd, app->opts.key)); /* it may already be held */
}

/* --- lifecycle ---------------------------------------------------------- */

static void
on_closed(void *userdata)
{
	struct app *app = userdata;
	app->api->quit(app->api, app->exit_code);
}

/* Stops listening, then quits once the microphone is confirmed muted. */
static void
shut_down(struct app *app, int exit_code)
{
	if (app->quitting)
	{
		return;
	}
	app->quitting = true;
	app->exit_code = exit_code;
	cancel_retry(app);
	detach_device(app);
	gate_close(&app->gate, on_closed);
}

static void
on_ready(void *userdata)
{
	attach_device(userdata);
}

/* Exit non-zero so systemd's Restart=on-failure brings us back with the server. */
static void
on_lost(void *userdata)
{
	shut_down(userdata, 1);
}

static void
on_signal(pa_mainloop_api *api, pa_signal_event *event, int sig, void *userdata)
{
	(void)api;
	(void)event;
	(void)sig;
	shut_down(userdata, 0);
}

int
main(int argc, char *argv[])
{
	struct app app = {.fd = -1};

	switch (parse_args(argc, (const char *const *)argv, &app.opts, stdout, stderr))
	{
	case OPTS_DONE:
		return 0;
	case OPTS_ERROR:
		return 2;
	case OPTS_RUN:
		break;
	}

	pa_mainloop *loop = pa_mainloop_new();
	if (loop == NULL)
	{
		(void)fprintf(stderr, "cannot create main loop\n");
		return 1;
	}
	app.api = pa_mainloop_get_api(loop);

	int rc = 1;
	if (pa_signal_init(app.api) == 0)
	{
		pa_signal_new(SIGINT, on_signal, &app);
		pa_signal_new(SIGTERM, on_signal, &app);

		app.gate = (struct gate){
			.source = app.opts.source,
			.on_ready = on_ready,
			.on_lost = on_lost,
			.userdata = &app,
		};
		if (gate_connect(&app.gate, app.api) == 0 && pa_mainloop_run(loop, &rc) < 0)
		{
			rc = 1;
		}

		cancel_retry(&app);
		detach_device(&app);
		gate_free(&app.gate);
		pa_signal_done();
	}
	pa_mainloop_free(loop);
	return rc;
}
