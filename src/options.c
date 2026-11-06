#include "options.h"

#include <errno.h>
#include <linux/input.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#ifndef PTT_GATE_VERSION
#define PTT_GATE_VERSION "unknown"
#endif

struct key_name
{
	const char *name;
	unsigned short code;
};

/* Keys that make sense to hold for push-to-talk. Anything else can still be
 * given by number, from linux/input-event-codes.h. */
static const struct key_name KEY_NAMES[] = {
	{"KEY_F13", KEY_F13},
	{"KEY_F14", KEY_F14},
	{"KEY_F15", KEY_F15},
	{"KEY_F16", KEY_F16},
	{"KEY_F17", KEY_F17},
	{"KEY_F18", KEY_F18},
	{"KEY_F19", KEY_F19},
	{"KEY_F20", KEY_F20},
	{"KEY_F21", KEY_F21},
	{"KEY_F22", KEY_F22},
	{"KEY_F23", KEY_F23},
	{"KEY_F24", KEY_F24},
	{"KEY_CAPSLOCK", KEY_CAPSLOCK},
	{"KEY_SCROLLLOCK", KEY_SCROLLLOCK},
	{"KEY_PAUSE", KEY_PAUSE},
	{"KEY_LEFTCTRL", KEY_LEFTCTRL},
	{"KEY_RIGHTCTRL", KEY_RIGHTCTRL},
	{"KEY_LEFTALT", KEY_LEFTALT},
	{"KEY_RIGHTALT", KEY_RIGHTALT},
	{"KEY_LEFTMETA", KEY_LEFTMETA},
	{"KEY_RIGHTMETA", KEY_RIGHTMETA},
	{"BTN_SIDE", BTN_SIDE},
	{"BTN_EXTRA", BTN_EXTRA},
	{"BTN_FORWARD", BTN_FORWARD},
	{"BTN_BACK", BTN_BACK},
};

#define KEY_PREFIX	   "KEY_"
#define KEY_PREFIX_LEN (sizeof KEY_PREFIX - 1)

static bool
parse_number(const char *text, unsigned short *code)
{
	char *end = NULL;
	errno = 0;
	long value = strtol(text, &end, 0);
	if (errno != 0 || end == text || *end != '\0' || value <= 0 || value > KEY_MAX)
	{
		return false;
	}
	*code = (unsigned short)value;
	return true;
}

bool
parse_key(const char *text, unsigned short *code)
{
	if (parse_number(text, code))
	{
		return true;
	}
	for (size_t i = 0; i < sizeof KEY_NAMES / sizeof KEY_NAMES[0]; i++)
	{
		const char *name = KEY_NAMES[i].name;
		bool short_form =
			strncmp(name, KEY_PREFIX, KEY_PREFIX_LEN) == 0 && strcasecmp(text, name + KEY_PREFIX_LEN) == 0;
		if (strcasecmp(text, name) == 0 || short_form)
		{
			*code = KEY_NAMES[i].code;
			return true;
		}
	}
	return false;
}

static void
usage(FILE *out)
{
	(void)fprintf(out,
				  "Usage: ptt-gate [options]\n"
				  "Unmutes the microphone while a key is held, muted otherwise.\n"
				  "\n"
				  "  -d, --device NAME   input device to listen on (default: %s)\n"
				  "  -k, --key KEY       key to hold: KEY_F24, F24 or a numeric code (default: KEY_F24)\n"
				  "  -s, --source NAME   PulseAudio/PipeWire source (default: %s)\n"
				  "  -v, --verbose       log every press and release\n"
				  "  -h, --help          show this help\n"
				  "  -V, --version       show the version\n",
				  DEFAULT_DEVICE, DEFAULT_SOURCE);
}

static bool
is_flag(const char *arg, const char *short_name, const char *long_name)
{
	return strcmp(arg, short_name) == 0 || strcmp(arg, long_name) == 0;
}

/* The value after the option at argv[*i], advancing past it. */
static const char *
take_value(int argc, const char *const argv[], int *i, FILE *err)
{
	if (*i + 1 >= argc || argv[*i + 1][0] == '\0')
	{
		(void)fprintf(err, "ptt-gate: %s needs a value\n", argv[*i]);
		return NULL;
	}
	*i += 1;
	return argv[*i];
}

enum parse_result
parse_args(int argc, const char *const argv[], struct options *opts, FILE *out, FILE *err)
{
	*opts = (struct options){.device = DEFAULT_DEVICE, .source = DEFAULT_SOURCE, .key = KEY_F24};

	for (int i = 1; i < argc; i++)
	{
		const char *arg = argv[i];

		if (is_flag(arg, "-h", "--help"))
		{
			usage(out);
			return OPTS_DONE;
		}
		if (is_flag(arg, "-V", "--version"))
		{
			(void)fprintf(out, "ptt-gate %s\n", PTT_GATE_VERSION);
			return OPTS_DONE;
		}
		if (is_flag(arg, "-v", "--verbose"))
		{
			opts->verbose = true;
			continue;
		}
		bool is_device = is_flag(arg, "-d", "--device");
		bool is_source = is_flag(arg, "-s", "--source");
		bool is_key = is_flag(arg, "-k", "--key");
		if (!is_device && !is_source && !is_key)
		{
			(void)fprintf(err, "ptt-gate: unknown option '%s'\nTry 'ptt-gate --help'.\n", arg);
			return OPTS_ERROR;
		}

		const char *value = take_value(argc, argv, &i, err);
		if (value == NULL)
		{
			return OPTS_ERROR;
		}
		if (is_device)
		{
			opts->device = value;
		}
		else if (is_source)
		{
			opts->source = value;
		}
		else if (!parse_key(value, &opts->key))
		{
			(void)fprintf(err, "ptt-gate: unknown key '%s' (try KEY_F24 or a code from input-event-codes.h)\n", value);
			return OPTS_ERROR;
		}
	}
	return OPTS_RUN;
}
