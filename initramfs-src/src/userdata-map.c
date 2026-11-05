// SPDX-License-Identifier: GPL-2.0-only
/* Minimal early-boot DM/keyring interface. No plaintext keys in argv/logs. */
#define _GNU_SOURCE
#include <errno.h>
#include <endian.h>
#include <fcntl.h>
#include <linux/dm-ioctl.h>
#include <linux/fs.h>
#include <linux/keyctl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/quota.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define NAME "android-data-root"
#define NODE "/dev/mapper/" NAME
static unsigned char buffer[4096];
static int control = -1;

static uint32_t get32(const void *p)
{
	uint32_t v;
	memcpy(&v, p, sizeof(v));
	return le32toh(v);
}

static uint64_t get64(const void *p)
{
	uint64_t v;
	memcpy(&v, p, sizeof(v));
	return le64toh(v);
}

static int valid_checkpoint(const unsigned char *p)
{
	uint32_t off = get32(p + 164), crc = 0xf2f52010;
	if (off < 192 || off > 4092) return 0;
	for (uint32_t i = 0; i < off; i++) {
		crc ^= p[i];
		for (int bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (0xedb88320U & (0U - (crc & 1)));
	}
	return crc == get32(p + off);
}

/* Do not commit an Android checkpoint transaction or ignore repair flags. */
static int check_writable(const char *path)
{
	unsigned char sb[4096], cp[2][4096], tail[4096];
	int fd = open(path, O_RDONLY | O_CLOEXEC), valid[2] = {0}, chosen;
	uint32_t base, seg_blocks, flags;
	if (fd < 0) return 1;
	if ((pread(fd, sb, sizeof(sb), 1024) != 4096 ||
	     get32(sb) != 0xf2f52010) &&
	    (pread(fd, sb, sizeof(sb), 5120) != 4096 ||
	     get32(sb) != 0xf2f52010)) goto bad;
	if (get32(sb + 16) != 12 || get32(sb + 20) > 20) goto bad;
	base = get32(sb + 76);
	seg_blocks = 1U << get32(sb + 20);
	for (int i = 0; i < 2; i++) {
		uint64_t block = (uint64_t)base + (uint64_t)i * seg_blocks;
		uint32_t count;
		if (pread(fd, cp[i], 4096, block * 4096) != 4096 ||
		    !valid_checkpoint(cp[i])) continue;
		count = get32(cp[i] + 136);
		if (count < 2 || count > seg_blocks ||
		    pread(fd, tail, 4096, (block + count - 1) * 4096) != 4096 ||
		    !valid_checkpoint(tail) || get64(cp[i]) != get64(tail)) continue;
		valid[i] = 1;
	}
	if (!valid[0] && !valid[1]) goto bad;
	chosen = valid[1] && (!valid[0] ||
		(int64_t)(get64(cp[1]) - get64(cp[0])) > 0);
	flags = get32(cp[chosen] + 132);
	printf("userdata checkpoint flags=0x%x\n", flags);
	close(fd);
	if (flags & 0x1818) {
		fprintf(stderr, "userdata: Android checkpoint pending or filesystem repair required; refusing write mount\n");
		return 1;
	}
	return 0;
bad:
	fprintf(stderr, "userdata: cannot validate F2FS checkpoints\n");
	close(fd);
	return 1;
}

static struct dm_ioctl *header(void)
{
	struct dm_ioctl *d = (void *)buffer;
	memset(buffer, 0, sizeof(buffer));
	d->version[0] = DM_VERSION_MAJOR;
	d->data_size = sizeof(buffer);
	d->data_start = (sizeof(*d) + 7) & ~7;
	strcpy(d->name, NAME);
	return d;
}

static int remove_mapping(void)
{
	header();
	if (ioctl(control, DM_DEV_REMOVE, buffer) < 0)
		return -1;
	unlink(NODE);
	return 0;
}

int main(int argc, char **argv)
{
	unsigned char key[101] = {0};
	uint64_t size;
	long serial = -1;
	int fd, created = 0, ret = 1;
	struct dm_ioctl *d;
	struct dm_target_spec *t;
	char *params;
	uint32_t dev;

	if (argc == 3 && !strcmp(argv[1], "check-writable"))
		return check_writable(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "quota-check")) {
		struct stat st;
		char path[128], link[512], features[2048];
		ssize_t n;
		if (stat(argv[2], &st)) return 1;
		snprintf(path, sizeof(path), "/sys/dev/block/%u:%u", major(st.st_rdev), minor(st.st_rdev));
		n = readlink(path, link, sizeof(link) - 1);
		if (n < 0) return 1;
		link[n] = 0;
		snprintf(path, sizeof(path), "/sys/fs/f2fs/%s/features", strrchr(link, '/') + 1);
		fd = open(path, O_RDONLY | O_CLOEXEC);
		if (fd < 0) return 1;
		n = read(fd, features, sizeof(features) - 1);
		close(fd);
		if (n <= 0) return 1;
		features[n] = 0;
		if (!strstr(features, "quota_ino")) return 0;
		for (int type = USRQUOTA; type <= PRJQUOTA; type++) {
			uint32_t format = 0;
			if (type == PRJQUOTA && !strstr(features, "projquota")) continue;
			if (quotactl(QCMD(Q_GETFMT, type), argv[2], 0,
				     (void *)&format) || format != QFMT_VFS_V1) {
				fprintf(stderr, "userdata: quota type %d unavailable\n", type);
				return 1;
			}
		}
		return 0;
	}
	if (!((argc == 4 && !strcmp(argv[1], "create")) ||
	      (argc == 2 && !strcmp(argv[1], "remove")))) {
		fprintf(stderr, "usage: userdata-map create DEVICE KEY | remove | quota-check DEVICE | check-writable DEVICE\n");
		return 2;
	}
	control = open("/dev/mapper/control", O_RDWR | O_CLOEXEC);
	if (control < 0) { perror("DM control"); return 1; }
	if (argc == 2) {
		ret = remove_mapping() ? 1 : 0;
		if (ret) perror("DM remove");
		close(control);
		return ret;
	}
	fd = open(argv[2], O_RDONLY | O_CLOEXEC);
	if (fd < 0) { perror("userdata"); goto out; }
	ret = ioctl(fd, BLKGETSIZE64, &size);
	close(fd);
	if (ret || !size || size % 4096) { fprintf(stderr, "invalid userdata size\n"); ret = 1; goto out; }
	fd = open(argv[3], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0) { perror("wrapped key"); ret = 1; goto out; }
	ret = read(fd, key, sizeof(key));
	close(fd);
	if (ret != 100) { fprintf(stderr, "expected 100-byte wrapped key\n"); ret = 1; goto out; }
	ret = 1;
	serial = syscall(SYS_add_key, "logon", "zhiyu:metadata-root", key, 100,
			 KEY_SPEC_PROCESS_KEYRING);
	explicit_bzero(key, sizeof(key));
	if (serial < 0) { perror("add_key"); goto out; }
	d = header();
	if (ioctl(control, DM_DEV_CREATE, d)) { perror("DM create"); goto out; }
	created = 1;
	dev = d->dev;
	d = header();
	d->target_count = 1;
	t = (void *)(buffer + d->data_start);
	t->length = size / 512;
	strcpy(t->target_type, "inlinecrypt-fbe");
	params = (char *)(t + 1);
	if (snprintf(params, sizeof(buffer) - (params - (char *)buffer),
		     "aes-xts-plain64 :100:logon:zhiyu:metadata-root 0 %s 0 3 sector_size:4096 iv_large_sectors keytype:hw-wrapped",
		     argv[2]) >= (int)(sizeof(buffer) - (params - (char *)buffer)))
		goto out;
	t->next = (sizeof(*t) + strlen(params) + 1 + 7) & ~7;
	if (ioctl(control, DM_TABLE_LOAD, d)) { perror("DM table"); goto out; }
	header();
	if (ioctl(control, DM_DEV_SUSPEND, buffer)) { perror("DM resume"); goto out; }
	mkdir("/dev/mapper", 0755);
	if (mknod(NODE, S_IFBLK | 0600,
		  makedev((dev & 0xfff00) >> 8, (dev & 0xff) | ((dev >> 12) & 0xfff00)))) {
		perror("DM node");
		goto out;
	}
	ret = 0;
out:
	explicit_bzero(key, sizeof(key));
	if (serial >= 0)
		syscall(SYS_keyctl, KEYCTL_REVOKE, serial);
	if (ret && created)
		remove_mapping();
	close(control);
	return ret;
}
