#include "device.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define DEVICE_DIR "/dev/input"
#define KEY_BITS   (KEY_MAX / 8 + 1)

static bool
test_bit(const unsigned char *bits, unsigned short bit)
{
	unsigned int i = bit;
	return (((unsigned int)bits[i / 8U] >> (i % 8U)) & 1U) != 0U;
}

static bool
matches(int fd, const char *name, unsigned short key)
{
	char actual[256] = {0};
	unsigned char keys[KEY_BITS] = {0};

	return ioctl(fd, EVIOCGNAME(sizeof actual - 1), actual) >= 0 && strcmp(actual, name) == 0 &&
		   ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keys), keys) >= 0 && test_bit(keys, key);
}

int
device_open(const char *name, unsigned short key, char *path, size_t path_len)
{
	DIR *dir = opendir(DEVICE_DIR);
	if (dir == NULL)
	{
		return -1;
	}
	int dir_fd = dirfd(dir);
	if (dir_fd < 0)
	{
		closedir(dir);
		return -1;
	}

	int found = -1;
	bool denied = false;
	const struct dirent *entry;
	while (found < 0 && (entry = readdir(dir)) != NULL)
	{
		if (strncmp(entry->d_name, "event", 5) != 0)
		{
			continue;
		}
		int fd = openat(dir_fd, entry->d_name, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
		{
			denied = denied || errno == EACCES;
			continue;
		}
		if (matches(fd, name, key))
		{
			(void)snprintf(path, path_len, DEVICE_DIR "/%s", entry->d_name);
			found = fd;
		}
		else
		{
			close(fd);
		}
	}
	closedir(dir);

	if (found < 0)
	{
		errno = denied ? EACCES : ENODEV;
	}
	return found;
}

bool
device_key_down(int fd, unsigned short key)
{
	unsigned char keys[KEY_BITS] = {0};
	return ioctl(fd, EVIOCGKEY(sizeof keys), keys) >= 0 && test_bit(keys, key);
}
