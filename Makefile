# Makefile for zoysh — LLM-powered zsh assistant

# Frameworks like oh-my-zsh export ZSH, and "?=" would let that leak into the
# check target. A plain assignment wins over the environment; pass ZSH=... on
# the make command line to override.
ZSH = zsh
PREFIX ?= $(HOME)/.local
DESTDIR ?=
INSTALL ?= install
CC ?= cc

PLUGIN := zoysh.plugin.zsh
PLUGIN_DIR := $(DESTDIR)$(PREFIX)/share/zsh/plugins/zoysh
MODULE_SO := zoysh.so
MODULE_SRCS := src/zoysh.c src/vendor/cJSON/cJSON.c
MODULE_HDRS := src/zoysh.mdh
ZSH_SRC ?= $(HOME)/src/zsh
# Extra include paths the configured zsh tree may need (for example a
# curses/term header location); empty by default.
ZSH_EXTRA_CFLAGS ?=
MODULE_CFLAGS ?= -fPIC -shared -Wall -Wextra -O2 -g \
	-I$(ZSH_SRC)/Src -I$(ZSH_SRC)/Src/Zle -Isrc -Isrc/vendor/cJSON $(ZSH_EXTRA_CFLAGS)
MODULE_LIBS := $(shell curl-config --libs 2>/dev/null || echo -lcurl)

.DEFAULT_GOAL := check

.PHONY: all check syntax test install uninstall module check-module clean

all: check

check: syntax test

syntax:
	$(ZSH) -n $(PLUGIN)
	$(ZSH) -n tests/test.zsh
	$(ZSH) -n tests/module.test.zsh

test:
	$(ZSH) -f -c 'source ./$(PLUGIN); (( ! $${+functions[yo]} ))'
	$(ZSH) -f -i tests/test.zsh
	$(ZSH) -f -i -c 'ZOYSH_CONF=/dev/null; source ./$(PLUGIN); source ./$(PLUGIN); (( $${+functions[yo]} )); yo --version >/dev/null'

install: check
	mkdir -p "$(PLUGIN_DIR)"
	$(INSTALL) -m 0644 "$(PLUGIN)" "$(PLUGIN_DIR)/$(PLUGIN)"
	@echo "Installed $(PLUGIN_DIR)/$(PLUGIN)"
	@echo "Add this to ~/.zshrc: source $(PREFIX)/share/zsh/plugins/zoysh/$(PLUGIN)"

uninstall:
	rm -f "$(PLUGIN_DIR)/$(PLUGIN)"

# Experimental native module. It is deliberately opt-in: "make check" never
# requires it. Set ZSH_SRC to a configured zsh source tree (see README).
module:
	@test -f src/vendor/cJSON/cJSON.c || { \
		echo "module: src/vendor/cJSON/cJSON.c is missing" >&2; \
		exit 1; \
	}
	@test -f $(ZSH_SRC)/Src/zsh.mdh -a -f $(ZSH_SRC)/config.h || { \
		echo "module: set ZSH_SRC to a configured zsh source tree (see README)" >&2; \
		exit 1; \
	}
	$(CC) $(MODULE_CFLAGS) -o $(MODULE_SO) $(MODULE_SRCS) $(MODULE_LIBS) -lm

# Module tests: only meaningful after "make module"; never part of check.
check-module: module
	ZMODULE=1 $(ZSH) -f -i tests/module.test.zsh

clean:
	rm -f $(MODULE_SO) src/*.o src/vendor/cJSON/*.o src/*.mdh src/*.pro src/*.mdhi
