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
 * Messages go to stdout/stderr and to Android's log (logcat tag "pbmixer"): init's stdio_to_kmsg only works on
 * debuggable builds, so the log socket is used directly, in the record format liblog writes.
 * Static build: gcc -O2 -static -o pbmixer pbmixer.c
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <sound/asound.h>

enum { LOG_INFO = 4, LOG_ERROR = 6 };

/* one record to logd: {log id, tid, realtime} header, then priority, tag and message (liblog's logd writer) */
static void plog(int prio, const char *fmt, ...)
{
	static int fd = -2;
	char msg[400];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	fprintf(prio >= LOG_ERROR ? stderr : stdout, "pbmixer: %s\n", msg);
	if (fd == -2) {
		struct sockaddr_un sa = { .sun_family = AF_UNIX, .sun_path = "/dev/socket/logdw" };
		fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
		if (fd >= 0 && connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
			close(fd);
			fd = -1;
		}
	}
	if (fd < 0)
		return;
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	unsigned char hdr[11], pr = (unsigned char)prio;
	uint16_t tid = (uint16_t)syscall(SYS_gettid);
	uint32_t sec = (uint32_t)ts.tv_sec, nsec = (uint32_t)ts.tv_nsec;
	hdr[0] = 0;	/* LOG_ID_MAIN */
	memcpy(hdr + 1, &tid, 2);
	memcpy(hdr + 3, &sec, 4);
	memcpy(hdr + 7, &nsec, 4);
	struct iovec iov[4] = { { hdr, sizeof(hdr) }, { &pr, 1 }, { (void *)"pbmixer", 8 }, { msg, strlen(msg) + 1 } };
	if (writev(fd, iov, 4) < 0) { /* logging is best effort */ }
}

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
		plog(LOG_ERROR, "usage: %s <config>", argv[0]);
		return 2;
	}
	FILE *f = fopen(argv[1], "r");
	if (!f) {
		plog(LOG_ERROR, "%s: %s", argv[1], strerror(errno));
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
			plog(LOG_ERROR, "bad line: %s", line);
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
				plog(LOG_ERROR, "card %s not found", card);
				if (nmissing < 16)
					snprintf(missing[nmissing++], sizeof(missing[0]), "%.31s", card);
			}
			failures++;
			continue;
		}
		int rc = set_control(fd, name, value);
		close(fd);
		if (rc) {
			plog(LOG_ERROR, "%s: '%s' = '%s': %s", card, name, value, strerror(-rc));
			failures++;
		} else {
			plog(LOG_INFO, "%s: '%s' = '%s'", card, name, value);
		}
	}
	fclose(f);
	plog(failures ? LOG_ERROR : LOG_INFO, "done, %d failure(s)", failures);
	return failures ? 1 : 0;
}
