#ifndef DEVICE_H
#define DEVICE_H

#include <stdbool.h>
#include <stddef.h>

/* Opens the first /dev/input/event* whose name is `name` and which can emit
 * `key`, non-blocking and without grabbing it, so other readers (the
 * compositor) still see every key. Writes the device path to `path` for
 * logging. Returns the fd, or -1 with errno set to EACCES when some device
 * could not be opened for lack of permission (the user is not in the `input`
 * group), ENODEV otherwise. */
int
device_open(const char *name, unsigned short key, char *path, size_t path_len);

/* Whether `key` is held right now, from the kernel's key state rather than the
 * event stream: used at startup and after events were dropped. */
bool
device_key_down(int fd, unsigned short key);

#endif
