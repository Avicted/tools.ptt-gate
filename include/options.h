#ifndef OPTIONS_H
#define OPTIONS_H

#include <stdbool.h>
#include <stdio.h>

#define DEFAULT_DEVICE "keyd virtual keyboard"
#define DEFAULT_SOURCE "@DEFAULT_SOURCE@"

struct options
{
	const char *device; /* input device name, as reported by EVIOCGNAME */
	const char *source; /* PulseAudio/PipeWire source name */
	unsigned short key; /* evdev key code */
	bool verbose;
};

enum parse_result
{
	OPTS_RUN,	/* options are valid: start the gate */
	OPTS_DONE,	/* --help or --version was printed: exit 0 */
	OPTS_ERROR, /* usage error, already reported on `err`: exit 2 */
};

/* Fills `opts` from argv, starting from the defaults. Output goes to `out`,
 * diagnostics to `err`, so the parser can be tested without a terminal. */
enum parse_result
parse_args(int argc, const char *const argv[], struct options *opts, FILE *out, FILE *err);

/* Accepts a kernel key name (KEY_F24, BTN_SIDE), the same without the KEY_
 * prefix (F24), in any case, or a numeric code (decimal or 0x hex). */
bool
parse_key(const char *text, unsigned short *code);

#endif
