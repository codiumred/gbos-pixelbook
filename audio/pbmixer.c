// SPDX-License-Identifier: MIT
/*
 * pbmixer: set ALSA mixer controls by card id and control name, from a config file. Google's dras audio HAL applies
 * mixer paths only to the primary (speaker) card, but the Pixelbook's headset codec (RT5663, card avsrt5663) and
 * internal microphones (RT5514, card avsrt5514) are separate cards whose routing switches start off. This tool
 * applies ChromeOS's settings for those cards once at boot (see audio/pbmixer.conf and image/patch_oem.sh).
 *
 *   pbmixer <config file>
 * Config lines: <card id>|<control name>|<value>, '#' starts a comment. Values: integers (all channels), on/off for
 * switches, or the item name for enumerated controls. Cards that do not exist (yet) are retried for up to 20 s.
 * Static build: gcc -O2 -static -o pbmixer pbmixer.c
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <sound/asound.h>

static int open_card(const char *id)
{
	for (int c = 0; c < 32; c++) {
		char path[64];
		snprintf(path, sizeof(path), "/dev/snd/controlC%d", c);
		int fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		struct snd_ctl_card_info info;
		memset(&info, 0, sizeof(info));
		if (ioctl(fd, SNDRV_CTL_IOCTL_CARD_INFO, &info) == 0 && strcmp((char *)info.id, id) == 0)
			return fd;
		close(fd);
	}
	return -1;
}

static int set_control(int fd, const char *name, const char *value)
{
	struct snd_ctl_elem_info info;
	memset(&info, 0, sizeof(info));
	info.id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
	snprintf((char *)info.id.name, sizeof(info.id.name), "%s", name);
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) < 0)
		return -errno;

	struct snd_ctl_elem_value v;
	memset(&v, 0, sizeof(v));
	v.id = info.id;
	unsigned int n = info.count;
	switch (info.type) {
	case SNDRV_CTL_ELEM_TYPE_BOOLEAN: {
		int on = !strcmp(value, "on") || !strcmp(value, "1") || !strcmp(value, "true");
		for (unsigned int i = 0; i < n && i < 128; i++)
			v.value.integer.value[i] = on;
		break;
	}
	case SNDRV_CTL_ELEM_TYPE_INTEGER: {
		char *end;
		long x = strtol(value, &end, 10);
		if (*end)
			return -EINVAL;
		if (x < info.value.integer.min || x > info.value.integer.max)
			return -ERANGE;
		for (unsigned int i = 0; i < n && i < 128; i++)
			v.value.integer.value[i] = x;
		break;
	}
	case SNDRV_CTL_ELEM_TYPE_ENUMERATED: {
		unsigned int items = info.value.enumerated.items, found = items;
		for (unsigned int i = 0; i < items; i++) {
			info.value.enumerated.item = i;
			if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) < 0)
				return -errno;
			if (!strcmp(info.value.enumerated.name, value)) {
				found = i;
				break;
			}
		}
		if (found == items)
			return -ENOENT;
		for (unsigned int i = 0; i < n && i < 128; i++)
			v.value.enumerated.item[i] = found;
		break;
	}
	default:
		return -EOPNOTSUPP;
	}
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &v) < 0)
		return -errno;
	return 0;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <config>\n", argv[0]);
		return 2;
	}
	FILE *f = fopen(argv[1], "r");
	if (!f) {
		perror(argv[1]);
		return 2;
	}
	char line[512], missing[16][32];
	int failures = 0, nmissing = 0;
	while (fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\r\n")] = 0;
		if (!line[0] || line[0] == '#')
			continue;
		char *card = line, *name = strchr(line, '|'), *value;
		if (!name || !(value = strchr(name + 1, '|'))) {
			fprintf(stderr, "pbmixer: bad line: %s\n", line);
			failures++;
			continue;
		}
		*name++ = 0;
		*value++ = 0;
		int fd = -1, known_missing = 0;
		for (int i = 0; i < nmissing; i++)
			known_missing |= !strcmp(missing[i], card);
		for (int tries = 0; tries < (known_missing ? 1 : 40) && (fd = open_card(card)) < 0; tries++)
			usleep(500000);	/* the sound cards appear a few seconds into boot */
		if (fd < 0) {
			if (!known_missing) {
				fprintf(stderr, "pbmixer: card %s not found\n", card);
				if (nmissing < 16)
					snprintf(missing[nmissing++], sizeof(missing[0]), "%.31s", card);
			}
			failures++;
			continue;
		}
		int rc = set_control(fd, name, value);
		close(fd);
		if (rc) {
			fprintf(stderr, "pbmixer: %s: '%s' = '%s': %s\n", card, name, value, strerror(-rc));
			failures++;
		} else {
			printf("pbmixer: %s: '%s' = '%s'\n", card, name, value);
		}
	}
	fclose(f);
	return failures ? 1 : 0;
}
