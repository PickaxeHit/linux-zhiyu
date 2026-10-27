CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
PKGS = gio-2.0 glib-2.0

sensord: sensord.c
	$(CC) $(CFLAGS) -o $@ $< $(shell pkg-config --cflags --libs $(PKGS)) -lm

clean:
	rm -f sensord
