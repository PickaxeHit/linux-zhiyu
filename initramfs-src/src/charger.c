// SPDX-License-Identifier: GPL-2.0-only
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <time.h>
#include <unistd.h>

#define USB "/sys/class/power_supply/qcom-battmgr-usb/online"
#define CAPACITY "/sys/class/power_supply/qcom-battmgr-bat/capacity"
#define MIN_DISPLAY_MS 4000
#define FRAME_MS 100
#define HOLD_MS 1500
#define UNPLUG_MS 1000

static long long now_ms(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return now.tv_sec * 1000LL + now.tv_nsec / 1000000;
}

static int read_number(const char *path)
{
	FILE *file = fopen(path, "r");
	int value = -1;

	if (file) {
		if (fscanf(file, "%d", &value) != 1)
			value = -1;
		fclose(file);
	}
	return value;
}

static bool set_brightness(const char *path, int value)
{
	FILE *file = fopen(path, "w");

	if (!file)
		return false;
	int result = fprintf(file, "%d\n", value);
	return fclose(file) == 0 && result > 0;
}

static int open_power_key(void)
{
	glob_t devices;
	int fd = -1;

	if (glob("/dev/input/event*", 0, NULL, &devices))
		return -1;
	for (size_t i = 0; i < devices.gl_pathc; i++) {
		char name[64] = { 0 };

		fd = open(devices.gl_pathv[i], O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 &&
		    !strcmp(name, "pmic_pwrkey"))
			break;
		close(fd);
		fd = -1;
	}
	globfree(&devices);
	return fd;
}

/*
 * Charging screen.
 *
 * Everything is drawn on a square-pixel canvas: one 8x16 console cell holds two
 * vertically stacked 8x8 pixels, emitted as U+2580 (upper half block) with
 * fg = top pixel and bg = bottom pixel.  Only the 8 colours that are valid as
 * console backgrounds are used; their RGB values are reprogrammed through the
 * vt palette (ESC ] P), which also gives palette-only animation (low battery
 * breathing) without touching the pixels.
 */
enum { C_BG, C_TRACK, C_SHADE, C_BASE, C_LIGHT, C_GLOSS, C_EDGE, C_WHITE };

/* ESC ] P n rrggbb takes the ANSI colour number n (not the VGA hardware index) */
static const unsigned ramp[3][8] = {
	/* bg      track     shade     base      light     gloss     edge      white */
	{ 0x000000, 0x16221b, 0x0b6b2f, 0x13a247, 0x2fd568, 0x9af7bb, 0xb4bcc4, 0xffffff },
	{ 0x000000, 0x241e12, 0x7a4f08, 0xc98a0e, 0xf6b930, 0xffe6a0, 0xb4bcc4, 0xffffff },
	{ 0x000000, 0x261616, 0x7a1414, 0xc02626, 0xf04b4b, 0xffb0a8, 0xb4bcc4, 0xffffff },
};

/* 5x7 digits 0-9, '%' (10), '-' (11) */
static const unsigned char font[12][7] = {
	{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
	{ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
	{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F },
	{ 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E },
	{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
	{ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
	{ 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E },
	{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
	{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
	{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C },
	{ 0x19, 0x1A, 0x02, 0x04, 0x08, 0x0B, 0x13 },
	{ 0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00 },
};

/* lightning bolt, unit square */
static const float bolt[6][2] = {
	{ .65f, 0 }, { .15f, .58f }, { .45f, .58f },
	{ .30f, 1 }, { .85f, .38f }, { .55f, .38f },
};

#define SWEEP_FRAMES 24		/* shine travels for 2.4 s ... */
#define CYCLE_FRAMES 32		/* ... then rests for 0.8 s */

static struct {
	int W, H, bw, nub, nubh, T, B, R, iw, ih, ri;
	int cap, filled, hl, sweep;
	bool chg, shine;
	int bx, by, bwid, bhei;
	int sc, tx, ty, ng;
	unsigned char glyph[4];
} g;

static int imax(int a, int b)
{
	return a > b ? a : b;
}

/* pixel (x,y) inside a w*h rounded rectangle of corner radius r */
static bool rr(int x, int y, int w, int h, int r)
{
	if (x < 0 || y < 0 || x >= w || y >= h)
		return false;
	if (r > w / 2)
		r = w / 2;
	if (r > h / 2)
		r = h / 2;
	if (r <= 0)
		return true;

	int cx = 2 * x + 1, cy = 2 * y + 1;
	int dx = cx < 2 * r ? 2 * r - cx : cx > 2 * (w - r) ? cx - 2 * (w - r) : 0;
	int dy = cy < 2 * r ? 2 * r - cy : cy > 2 * (h - r) ? cy - 2 * (h - r) : 0;

	return dx * dx + dy * dy <= 4 * r * r;
}

static bool in_bolt(int x, int y)
{
	if (x < 0 || y < 0 || x >= g.bwid || y >= g.bhei)
		return false;

	float px = (x + .5f) / g.bwid, py = (y + .5f) / g.bhei;
	bool in = false;

	for (int i = 0, j = 5; i < 6; j = i++)
		if ((bolt[i][1] > py) != (bolt[j][1] > py) &&
		    px < (bolt[j][0] - bolt[i][0]) * (py - bolt[i][1]) /
			 (bolt[j][1] - bolt[i][1]) + bolt[i][0])
			in = !in;
	return in;
}

/* white bolt with a 1px dark outline; -1 = not part of the bolt */
static int bolt_px(int x, int y)
{
	if (in_bolt(x, y))
		return C_WHITE;
	if (in_bolt(x - 1, y) || in_bolt(x + 1, y) ||
	    in_bolt(x, y - 1) || in_bolt(x, y + 1))
		return C_BG;
	return -1;
}

static bool text_px(int x, int y)
{
	x -= g.tx;
	y -= g.ty;
	if (x < 0 || y < 0 || y >= 7 * g.sc)
		return false;

	int cell = x / (6 * g.sc), col = x % (6 * g.sc) / g.sc;

	if (cell >= g.ng || col >= 5)
		return false;
	return font[g.glyph[cell]][y / g.sc] >> (4 - col) & 1;
}

/* vertical gradient, glossy top line, soft leading edge, travelling shine */
static int fill_tone(int fx, int fy)
{
	static const unsigned char bayer[4] = { 0, 2, 3, 1 };
	int c = fy < g.hl ? C_GLOSS :
		fy * 100 < g.ih * 45 ? C_LIGHT :
		fy * 100 < g.ih * 85 ? C_BASE : C_SHADE;

	if (g.shine) {
		int d = abs(fx - (g.sweep + (g.ih / 2 - fy) / 2));
		int th = bayer[(fy & 1) * 2 + (fx & 1)];

		if ((d < 2 || (d == 2 && th < 2) || (d == 3 && th < 1)) && c < C_GLOSS)
			c++;
	}
	if (g.filled < g.iw && fx >= g.filled - 2 && c < C_GLOSS)
		c++;
	return c;
}

static int pixel(int x, int y)
{
	int c, fx, fy;

	if (y >= g.H)
		return text_px(x, y) ? C_WHITE : C_BG;
	if (x >= g.bw) {
		if (rr(x - (g.bw - g.nub), y - (g.H - g.nubh) / 2, 2 * g.nub, g.nubh, g.nub))
			return g.cap >= 100 ? C_LIGHT : C_EDGE;
		return C_BG;
	}
	if (!rr(x, y, g.bw, g.H, g.R))
		return C_BG;
	if (!rr(x - g.T, y - g.T, g.bw - 2 * g.T, g.H - 2 * g.T, g.R - g.T))
		return C_EDGE;

	fx = x - g.B;
	fy = y - g.B;
	c = C_BG;
	if (rr(fx, fy, g.iw, g.ih, g.ri)) {
		c = C_TRACK;
		if (rr(fx, fy, g.filled, g.ih, g.ri))
			c = fill_tone(fx, fy);
	}
	if (g.chg) {
		int b = bolt_px(x - g.bx, y - g.by);

		if (b >= 0)
			c = b;
	}
	return c;
}

static void draw(FILE *tty, int capacity, unsigned int frame, bool charging)
{
	static char out[1 << 17];	/* 120x39 cells * 13 bytes worst case < 64K */
	static int pal_key = -1;
	struct winsize size;
	char label[8], *p = out;
	int level, tri, t, rows, left, top, fg = -1, bg = -1;

	if (ioctl(fileno(tty), TIOCGWINSZ, &size) < 0 ||
	    size.ws_col < 40 || size.ws_row < 20)
		size = (struct winsize){ .ws_col = 80, .ws_row = 25 };

	/* geometry, in canvas pixels */
	g.W = size.ws_col / 3;
	if (g.W < 24)
		g.W = 24;
	if (g.W > 120)
		g.W = 120;
	g.H = (g.W * 2 / 5) & ~1;
	g.sc = imax(g.W / 40, 1);
	g.nub = imax(g.W / 24, 2);
	g.nubh = (g.H * 2 / 5) & ~1;
	g.bw = g.W - g.nub;
	g.T = imax(g.H / 24, 1);
	g.B = g.T + 1 + (g.H >= 40);
	g.R = imax(g.H / 4, g.T + 1);
	g.iw = g.bw - 2 * g.B;
	g.ih = g.H - 2 * g.B;
	g.ri = imax(g.R - g.B, 0);
	g.hl = g.ih >= 10 ? g.ih / 20 + 1 : 0;

	if (capacity >= 0 && capacity <= 100) {
		snprintf(label, sizeof(label), "%d%%", capacity);
		g.filled = (g.iw * capacity + 50) / 100;
	} else {
		capacity = -1;
		strcpy(label, "--%");
		g.filled = 0;
	}
	g.cap = capacity;
	g.ng = strlen(label);
	for (int i = 0; i < g.ng; i++)
		g.glyph[i] = label[i] == '%' ? 10 : label[i] == '-' ? 11 : label[i] - '0';
	g.tx = (g.bw - (6 * g.ng - 1) * g.sc) / 2;
	g.ty = g.H + 3 + 2 * g.sc;
	rows = (g.ty + 7 * g.sc + 1) / 2;
	left = (size.ws_col - g.W) / 2 + 1;
	top = (size.ws_row - rows) / 2 + 1;

	/* animation state */
	t = frame % CYCLE_FRAMES;
	g.chg = charging;
	g.shine = charging && capacity < 100 && t < SWEEP_FRAMES;
	if (g.shine) {
		int margin = g.ih / 4 + 4;

		g.sweep = t * (g.iw + 2 * margin) / (SWEEP_FRAMES - 1) - margin;
	}
	g.bhei = (g.ih * 3 / 4) & ~1;
	g.bwid = g.bhei * 4 / 5;
	g.bx = (g.bw - g.bwid) / 2;
	g.by = (g.H - g.bhei) / 2;

	/* palette: green / amber / red; red breathes (palette only, 1.6 s) */
	level = capacity < 0 ? 1 : capacity <= 15 ? 2 : capacity <= 30 ? 1 : 0;
	tri = 8;
	if (level == 2 && charging)
		tri = frame % 16 < 8 ? frame % 16 : 16 - frame % 16;
	if (pal_key != level * 9 + tri) {
		unsigned s = 112 + 143 * tri / 8;

		pal_key = level * 9 + tri;
		for (int a = 0; a < 8; a++) {
			unsigned v = ramp[level][a];
			unsigned r = v >> 16, gr = v >> 8 & 255, b = v & 255;

			if (level == 2 && a >= C_SHADE && a <= C_GLOSS) {
				r = r * s / 255;
				gr = gr * s / 255;
				b = b * s / 255;
			}
			p += sprintf(p, "\033]P%X%02X%02X%02X", a, r, gr, b);
		}
	}

	for (int r = 0; r < rows; r++) {
		p += sprintf(p, "\033[%d;%dH", top + r, left);
		for (int x = 0; x < g.W; x++) {
			int a = pixel(x, 2 * r), b = pixel(x, 2 * r + 1);

			if (bg != b)
				p += sprintf(p, "\033[4%dm", bg = b);
			if (a == b) {
				*p++ = ' ';
				continue;
			}
			if (fg != a)
				p += sprintf(p, "\033[3%dm", fg = a);
			memcpy(p, "\xE2\x96\x80", 3);	/* U+2580 */
			p += 3;
		}
	}
	p += sprintf(p, "\033[0m");
	fwrite(out, 1, p - out, tty);
	fflush(tty);
}

int main(void)
{
	glob_t backlight;
	int key = -1, brightness = -1, online = -1, capacity = -1;
	long long held_since = -1, earliest_blank, next_sample = 0;
	long long unplugged_since = -1, next_frame;
	unsigned int frame = 0;
	bool lit = true, key_released;
	FILE *tty = NULL;
	const char *path = NULL;
	unsigned char keys[KEY_MAX / 8 + 1] = { 0 };

	for (int i = 0; i < 20; i++) {
		if (key < 0)
			key = open_power_key();
		online = read_number(USB);
		if (!tty) {
			tty = fopen("/dev/tty1", "w");
			/* Buffer writes for each rendered frame. */
			if (tty)
				setvbuf(tty, NULL, _IOFBF, 1 << 17);
		}
		if (!path) {
			if (glob("/sys/class/backlight/aw99706*/brightness", 0,
				 NULL, &backlight) == 0)
				path = backlight.gl_pathv[0];
			else
				globfree(&backlight);
		}
		if (path)
			brightness = read_number(path);
		if (key >= 0 && online == 1 && tty && brightness >= 0 && access("/sys/class/graphics/fb0", F_OK) == 0)
			break;
		sleep(1);
	}
	if (key < 0 || online < 0 || !tty || brightness < 0 ||
	    access("/sys/class/graphics/fb0", F_OK) != 0) {
		fprintf(stderr, "charger: devices unavailable (key=%d, USB=%d, tty=%d, backlight=%d)\n",
			key, online, tty != NULL, brightness);
		return 1;
	}

	if (online != 1) {
		fprintf(stderr, "charger: external power did not come online\n");
		return 1;
	}

	int visible_brightness = brightness > 0 ? brightness : 32;
	key_released = ioctl(key, EVIOCGKEY(sizeof(keys)), keys) >= 0 &&
		!(keys[KEY_POWER / 8] & (1U << (KEY_POWER % 8)));
	fprintf(stderr, "charger: devices ready, initial power key %s\n",
		key_released ? "released" : "held or unknown");
	fputs("\033%G\033[?25l\033[0;37;40m\033[2J", tty);	/* UTF-8 for U+2580 */
	capacity = read_number(CAPACITY);
	draw(tty, capacity, frame++, true);
	if (!set_brightness(path, visible_brightness))
		goto restore;
	earliest_blank = now_ms() + MIN_DISPLAY_MS;
	next_frame = now_ms() + FRAME_MS;

	for (;;) {
		struct input_event event;
		struct pollfd input = { .fd = key, .events = POLLIN };
		int ready = poll(&input, 1, 100);
		long long now = now_ms();

		if ((ready < 0 && errno != EINTR) ||
		    (input.revents & (POLLERR | POLLHUP | POLLNVAL)))
			break;
		while (read(key, &event, sizeof(event)) == sizeof(event)) {
			if (event.type != EV_KEY || event.code != KEY_POWER)
				continue;
			if (event.value == 1 && key_released) {
				held_since = now;
				earliest_blank = now + MIN_DISPLAY_MS;
			} else if (event.value == 0) {
				if (held_since >= 0 && now - held_since >= HOLD_MS)
					goto boot;
				held_since = -1;
				key_released = true;
			}
		}
		if (now >= next_sample) {
			next_sample = now + 250;
			online = read_number(USB);
			if (online == 0 && unplugged_since < 0)
				unplugged_since = now;
			if (online != 0)
				unplugged_since = -1;
			if (unplugged_since >= 0 && now - unplugged_since >= UNPLUG_MS) {
				draw(tty, read_number(CAPACITY), 0, false);
				set_brightness(path, visible_brightness);
				sleep(1);
				if (read_number(USB) == 0) {
					fprintf(stderr, "charger: USB disconnected, powering off\n");
					sync();
					if (reboot(RB_POWER_OFF) < 0)
						perror("charger poweroff");
					break;
				}
				unplugged_since = -1;
			}
			capacity = read_number(CAPACITY);
		}
		if (held_since >= 0 && now - held_since >= HOLD_MS)
			goto boot;
		if (!lit && now < earliest_blank) {
			frame = 0;
			draw(tty, capacity, frame++, true);
			if (!set_brightness(path, visible_brightness)) {
				perror("charger backlight");
				break;
			}
			lit = true;
			now = now_ms();
			earliest_blank = now + MIN_DISPLAY_MS;
			next_frame = now + FRAME_MS;
		} else if (lit && now >= next_frame) {
			/* Let the final frame of the current cycle finish before blanking. */
			if (now >= earliest_blank &&
			    (capacity == 100 || frame % CYCLE_FRAMES == 0)) {
				if (!set_brightness(path, 0)) {
					perror("charger backlight");
					break;
				}
				lit = false;
			} else {
				draw(tty, capacity, frame++, true);
				next_frame = now + FRAME_MS;
			}
		}
	}
	goto restore;

boot:
	fprintf(stderr, "charger: power key held, rebooting\n");
	sync();
	if (reboot(RB_AUTOBOOT) < 0)
		perror("charger reboot");
restore:
	fputs("\033]R\033[0m\033[2J\033[H\033[?25h", tty);
	fflush(tty);
	set_brightness(path, brightness);
	fclose(tty);
	close(key);
	globfree(&backlight);
	return 1;
}
