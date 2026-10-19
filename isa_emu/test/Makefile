CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra
OUT ?= .

$(OUT)/difftest: difftest.c ../isa_emu_core.h
	$(CC) $(CFLAGS) -o $@ difftest.c

test: $(OUT)/difftest
	$(OUT)/difftest 2000000

.PHONY: test
