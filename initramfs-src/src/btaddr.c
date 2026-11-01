// SPDX-License-Identifier: GPL-2.0-only
/*
 * btaddr - set a Bluetooth controller's public address from the initramfs.
 *
 * The board keeps its factory BD address in the Android persist partition, the
 * same file the WLAN side already uses.  WLAN can be told its address with
 * "ip link set" because the MAC is a netdev attribute; a Bluetooth controller
 * has no netdev, and busybox has neither hcitool nor btmgmt (it has no
 * bluetooth code at all).  The kernel's management interface is small, though:
 * MGMT_OP_SET_PUBLIC_ADDRESS stores the address in hdev->public_addr and the
 * driver applies it through its set_bdaddr callback the next time the
 * controller is powered on, which is exactly what the "local-bd-address"
 * device tree property does - just at runtime, so the value can stay in the
 * persist partition instead of a board file.
 *
 *   btaddr hci0 68:92:68:53:4d:ce
 *
 * Exit codes: 0 = address set, 1 = usage/parse error, 2 = kernel rejected it,
 * 3 = communication failure.
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>

#ifndef BTPROTO_HCI
#define BTPROTO_HCI		1
#endif
#define HCI_CHANNEL_CONTROL	3
#define HCI_DEV_NONE		0xffff

#define MGMT_OP_SET_PUBLIC_ADDRESS	0x0039
#define MGMT_EV_CMD_COMPLETE		0x0001
#define MGMT_EV_CMD_STATUS		0x0002
#define MGMT_STATUS_SUCCESS		0x00

struct sockaddr_hci {
	unsigned short hci_family;
	unsigned short hci_dev;
	unsigned short hci_channel;
};

struct mgmt_hdr {
	unsigned short opcode;
	unsigned short index;
	unsigned short len;
} __attribute__((packed));

struct mgmt_cmd {
	struct mgmt_hdr hdr;
	unsigned char addr[6];
} __attribute__((packed));

static int parse_mac(const char *s, unsigned char out[6])
{
	unsigned int b[6];
	int i;

	if (sscanf(s, "%x:%x:%x:%x:%x:%x", &b[0], &b[1], &b[2], &b[3], &b[4],
		   &b[5]) != 6)
		return -1;

	for (i = 0; i < 6; i++) {
		if (b[i] > 0xff)
			return -1;
		out[5 - i] = (unsigned char)b[i];	/* little endian */
	}

	return 0;
}

static int parse_index(const char *s, unsigned short *index)
{
	if (sscanf(s, "hci%hu", index) != 1)
		return -1;
	return 0;
}

int main(int argc, char **argv)
{
	struct sockaddr_hci sa = {
		.hci_family = AF_BLUETOOTH,
		.hci_dev = HCI_DEV_NONE,
		.hci_channel = HCI_CHANNEL_CONTROL,
	};
	struct mgmt_cmd cmd;
	unsigned char rsp[32];
	unsigned short index;
	int fd, n;
	ssize_t r;

	if (argc != 3) {
		fprintf(stderr, "usage: %s hciN aa:bb:cc:dd:ee:ff\n", argv[0]);
		return 1;
	}
	memset(&cmd, 0, sizeof(cmd));
	if (parse_index(argv[1], &index) || parse_mac(argv[2], cmd.addr)) {
		fprintf(stderr, "btaddr: bad hci index or address\n");
		return 1;
	}

	cmd.hdr.opcode = MGMT_OP_SET_PUBLIC_ADDRESS;
	cmd.hdr.index = index;
	cmd.hdr.len = sizeof(cmd.addr);

	fd = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BTPROTO_HCI);
	if (fd < 0) {
		fprintf(stderr, "btaddr: socket: %s\n", strerror(errno));
		return 3;
	}
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa))) {
		fprintf(stderr, "btaddr: bind: %s\n", strerror(errno));
		return 3;
	}
	if (send(fd, &cmd, sizeof(cmd), 0) != (ssize_t)sizeof(cmd)) {
		fprintf(stderr, "btaddr: send: %s\n", strerror(errno));
		return 3;
	}

	/*
	 * The control channel also delivers unrelated events (index added and
	 * so on), so wait for the command complete/status that echoes our
	 * opcode: header, the 16 bit opcode that was answered, then the status.
	 */
	for (;;) {
		unsigned short ev, answered;

		r = recv(fd, rsp, sizeof(rsp), 0);
		if (r < (ssize_t)(sizeof(struct mgmt_hdr) + 3)) {
			fprintf(stderr, "btaddr: no reply from the kernel\n");
			close(fd);
			return 3;
		}

		ev = rsp[0] | (rsp[1] << 8);
		if (ev != MGMT_EV_CMD_COMPLETE && ev != MGMT_EV_CMD_STATUS)
			continue;

		answered = rsp[6] | (rsp[7] << 8);
		if (answered != MGMT_OP_SET_PUBLIC_ADDRESS)
			continue;

		n = rsp[8];
		break;
	}
	close(fd);

	if (n != MGMT_STATUS_SUCCESS) {
		fprintf(stderr, "btaddr: kernel rejected the address (status 0x%02x)\n", n);
		return 2;
	}

	return 0;
}
