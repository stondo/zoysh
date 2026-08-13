# Makefile for zoysh — LLM-powered zsh module
# Port of yosh (github.com/pizlonator/yosh) to zsh ZLE
#
# Phase 1: Pure zsh script (no build needed) — just source zoysh.plugin.zsh
# Phase 2: C loadable module (requires zsh headers)
#
# This Makefile targets Phase 2 (C module development).

ZSH := $(shell which zsh 2>/dev/null || echo /usr/bin/zsh)
ZSH_SRC ?= $(HOME)/src/zsh
PREFIX ?= $(HOME)/.local

# Module name
MODULE_NAME := zoysh

# Compiler flags
CC := gcc
CFLAGS := -fPIC -shared -Wall -Wextra -O2 -g \
    -I$(ZSH_SRC)/Src -I$(ZSH_SRC)/Src/Zle \
    -Isrc

# Source files (Phase 2 — currently just skeleton)
SRCS := src/zoysh.c
OBJS := $(SRCS:.c=.o)

# Output
MODULE_SO := $(MODULE_NAME).so

.PHONY: all clean install test

all: $(MODULE_SO)

# Generate zsh module header files (.mdh/.pro) from template
src/%.mdh: src/%.c
	@echo "Generating $@ (stub — zsh modimport needed)"
	@# Real build requires: $(ZSH) $(ZSH_SRC)/Src/mkmodentries.sh
	@touch $@

# Compile C module
$(MODULE_SO): $(SRCS) src/cJSON.c
	$(CC) $(CFLAGS) -o $@ $(SRCS) src/cJSON.c \
	    -lcurl -lm

# cJSON (from yosh/upstream — MIT licensed)
src/cJSON.c:
	@echo "Fetch cJSON from yosh or upstream:"
	@echo "  cp /tmp/yosh-ref/readline-8.2.13/cJSON.[ch] src/"
	@exit 1

# Install module
install: $(MODULE_SO)
	install -D $(MODULE_SO) $(PREFIX)/lib/zsh/$(MODULE_NAME)/$(MODULE_SO)
	install -D zoysh.plugin.zsh $(PREFIX)/share/zsh/plugins/$(MODULE_NAME)/$(MODULE_NAME).plugin.zsh
	@echo "Installed. Add to ~/.zshrc:"
	@echo "  module_path+=( $(PREFIX)/lib/zsh/$(MODULE_NAME) )"
	@echo "  zmodload zsh/$(MODULE_NAME)"
	@echo "OR (script mode):"
	@echo "  source $(PREFIX)/share/zsh/plugins/$(MODULE_NAME)/$(MODULE_NAME).plugin.zsh"

# Quick test (Phase 1 — script mode)
test:
	@echo "=== Phase 1: Script test ==="
	@ZSH_VERSION=$$($(ZSH) -c 'echo $$ZSH_VERSION') && echo "zsh $$ZSH_VERSION"
	@$(ZSH) -c 'source zoysh.plugin.zsh; yo --help'

clean:
	rm -f $(MODULE_SO) $(OBJS) src/*.mdh src/*.pro src/*.mdhi
