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
MODULE_SRCS := src/zoysh.c src/cJSON.c
ZSH_SRC ?= $(HOME)/src/zsh
MODULE_CFLAGS ?= -fPIC -shared -Wall -Wextra -O2 -g \
	-I$(ZSH_SRC)/Src -I$(ZSH_SRC)/Src/Zle -Isrc

.DEFAULT_GOAL := check

.PHONY: all check syntax test install uninstall module clean

all: check

check: syntax test

syntax:
	$(ZSH) -n $(PLUGIN)
	$(ZSH) -n tests/test.zsh

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

# Experimental Phase 2 module. It is deliberately opt-in until the port is complete.
module:
	@test -f src/cJSON.c || { \
		echo "module: src/cJSON.c is missing; the Phase 2 module is not release-ready" >&2; \
		exit 1; \
	}
	@test -f $(ZSH_SRC)/Src/zsh.mdh || { \
		echo "module: set ZSH_SRC to a configured zsh source tree" >&2; \
		exit 1; \
	}
	$(CC) $(MODULE_CFLAGS) -o $(MODULE_SO) $(MODULE_SRCS) -lcurl -lm

clean:
	rm -f $(MODULE_SO) src/*.o src/*.mdh src/*.pro src/*.mdhi
