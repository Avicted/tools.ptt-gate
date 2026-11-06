#include "options.h"

#include <linux/input.h>
#include <stdlib.h>
#include <string.h>

/* cmocka requires these, in this order, before its own header. */
#include <stdarg.h>
#include <stddef.h>
#include <setjmp.h>
#include <stdint.h>

#include <cmocka.h>

/* Output of one parse_args run, captured through memory streams. */
struct parsed
{
	enum parse_result result;
	struct options opts;
	char *out;
	char *err;
};

/* Parses a NULL-terminated argument list (program name excluded). */
static struct parsed
parse(const char *const args[])
{
	const char *argv[16] = {"ptt-gate"};
	int argc = 1;
	while (args[argc - 1] != NULL)
	{
		assert_true(argc < (int)(sizeof argv / sizeof argv[0]));
		argv[argc] = args[argc - 1];
		argc++;
	}

	struct parsed p = {0};
	size_t out_len = 0;
	size_t err_len = 0;
	FILE *out = open_memstream(&p.out, &out_len);
	FILE *err = open_memstream(&p.err, &err_len);
	assert_non_null(out);
	assert_non_null(err);

	p.result = parse_args(argc, argv, &p.opts, out, err);
	(void)fclose(out);
	(void)fclose(err);
	return p;
}

#define PARSE(...) parse((const char *const[]){__VA_ARGS__, NULL})

static void
parsed_free(struct parsed *p)
{
	free(p->out);
	free(p->err);
}

static void
defaults(void **unused)
{
	(void)unused;
	struct parsed p = parse((const char *const[]){NULL});

	assert_int_equal(p.result, OPTS_RUN);
	assert_string_equal(p.opts.device, DEFAULT_DEVICE);
	assert_string_equal(p.opts.source, DEFAULT_SOURCE);
	assert_int_equal(p.opts.key, KEY_F24);
	assert_false(p.opts.verbose);
	parsed_free(&p);
}

static void
every_option_is_applied(void **unused)
{
	(void)unused;
	struct parsed p = PARSE("-d", "My Keyboard", "--source", "mic", "-k", "f13", "-v");

	assert_int_equal(p.result, OPTS_RUN);
	assert_string_equal(p.opts.device, "My Keyboard");
	assert_string_equal(p.opts.source, "mic");
	assert_int_equal(p.opts.key, KEY_F13);
	assert_true(p.opts.verbose);
	assert_string_equal(p.err, "");
	parsed_free(&p);
}

static void
long_forms_are_applied(void **unused)
{
	(void)unused;
	struct parsed p = PARSE("--device", "kbd", "-s", "src", "--key", "BTN_SIDE", "--verbose");

	assert_int_equal(p.result, OPTS_RUN);
	assert_string_equal(p.opts.device, "kbd");
	assert_string_equal(p.opts.source, "src");
	assert_int_equal(p.opts.key, BTN_SIDE);
	assert_true(p.opts.verbose);
	parsed_free(&p);
}

static void
help_and_version_print_and_stop(void **unused)
{
	(void)unused;
	struct parsed p = PARSE("--help");
	assert_int_equal(p.result, OPTS_DONE);
	assert_non_null(strstr(p.out, "Usage: ptt-gate"));
	parsed_free(&p);

	p = PARSE("-V");
	assert_int_equal(p.result, OPTS_DONE);
	assert_non_null(strstr(p.out, "ptt-gate "));
	parsed_free(&p);
}

struct error_case
{
	const char *args[3];
	const char *message;
};

static void
usage_errors_are_reported(void **unused)
{
	(void)unused;
	static const struct error_case cases[] = {
		{{"--bogus", NULL}, "unknown option '--bogus'"},
		{{"-d", NULL}, "-d needs a value"},
		{{"-s", "", NULL}, "-s needs a value"},
		{{"-k", "NOPE", NULL}, "unknown key 'NOPE'"},
	};

	for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++)
	{
		struct parsed p = parse(cases[i].args);
		assert_int_equal(p.result, OPTS_ERROR);
		if (strstr(p.err, cases[i].message) == NULL)
		{
			fail_msg("expected \"%s\" in: %s", cases[i].message, p.err);
		}
		parsed_free(&p);
	}
}

struct key_case
{
	const char *text;
	bool ok;
	unsigned short code;
};

static void
key_names_and_numbers(void **unused)
{
	(void)unused;
	static const struct key_case cases[] = {
		{"KEY_F24", true, KEY_F24},
		{"F24", true, KEY_F24},
		{"key_f24", true, KEY_F24},
		{"btn_side", true, BTN_SIDE},
		{"194", true, KEY_F24},
		{"0xc2", true, KEY_F24},
		{"SIDE", false, 0}, /* only KEY_ names have a short form */
		{"0", false, 0},
		{"-5", false, 0},
		{"99999", false, 0},
		{"12abc", false, 0},
		{"", false, 0},
	};

	for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++)
	{
		unsigned short code = 0;
		bool ok = parse_key(cases[i].text, &code);
		if (ok != cases[i].ok || (ok && code != cases[i].code))
		{
			fail_msg("parse_key(\"%s\") = %d (code %u), expected %d (code %u)", cases[i].text, ok, code, cases[i].ok,
					 cases[i].code);
		}
	}
}

int
main(void)
{
	const struct CMUnitTest tests[] = {
		cmocka_unit_test(defaults),
		cmocka_unit_test(every_option_is_applied),
		cmocka_unit_test(long_forms_are_applied),
		cmocka_unit_test(help_and_version_print_and_stop),
		cmocka_unit_test(usage_errors_are_reported),
		cmocka_unit_test(key_names_and_numbers),
	};
	return cmocka_run_group_tests_name("options", tests, NULL, NULL);
}
