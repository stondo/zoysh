/*
 * SPDX-License-Identifier: GPL-3.0-only
 * Copyright (C) 2026 Stefano Tondo
 *
 * zoysh.mdh — zsh module definition header
 *
 * Declares the zoysh zsh module for LLM-powered shell assistance.
 * Port of yosh (github.com/pizlonator/yosh) readline integration to zsh ZLE.
 */

#include "zsh.mdh"

/* Module state */
typedef struct zoysh_state {
    int enabled;
    int continuation_active;
    char *provider;
    char *model;
    char *base_url;
    char *api_key;
} zoysh_state_t;

/* Module-level variables */
static zoysh_state_t zoysh_state = { 0 };

/* Interceptable functions */
# define INTERCEPTABLE_HOOK preexec_hook

/* ── Widget functions ─────────────────────────────────────────────────────── */

/* yo widget: called when user triggers yo (via builtin or keybinding) */
/**/
int
zoysh_yo_widget(char **args)
{
    /* Phase 2: C implementation of yo command via ZLE */
    /* For now, delegates to the zsh script function */
    return 0;
}

/* Accept-line hook: intercept Enter to detect yo prefix */
/**/
int
zoysh_accept_line(char **args)
{
    /* Phase 2: intercept line submission, detect "yo " prefix */
    return 0;
}

/* Continuation hook: fires at each new prompt for multi-step tasks */
/**/
int
zoysh_continuation_hook(UNUSED(char **args))
{
    /* Phase 2: check zoysh_state.continuation_active and fire next step */
    return 0;
}

/* ── Builtin: yo ──────────────────────────────────────────────────────────── */

/* The yo builtin command */
/**/
static int
bin_yo(char *name, char **argv, UNUSED(Options ops), UNUSED(int func))
{
    /*
     * Phase 2 implementation will:
     * 1. Join argv into a query string
     * 2. Call yo_call_llm() with the query
     * 3. Parse response (command vs chat)
     * 4. For commands: push to ZLE buffer via zle_setline()
     * 5. For chat: print formatted output
     */

    /* For now, print a notice that the C module is not yet implemented */
    fprintf(stderr,
        "\033[33mzoysh: C module not yet implemented. "
        "Using zsh script fallback.\033[0m\n"
        "Run: source zoysh.plugin.zsh\n");
    return 1;
}

/* ── Builtin: yo_clear ────────────────────────────────────────────────────── */

/**/
static int
bin_yo_clear(char *name, char **argv, UNUSED(Options ops), UNUSED(int func))
{
    /* Phase 2: clear session memory in C */
    return 0;
}

/* ── Module setup tables ──────────────────────────────────────────────────── */

static struct builtin bintab[] = {
    BUILTIN("yo",       0, bin_yo,       0, -1, 0, "", NULL),
    BUILTIN("yo_clear", 0, bin_yo_clear, 0,  0, 0, "", NULL),
};

static struct features module_features = {
    bintab,           /* builtins */
    NULL,             /* condition coders */
    NULL,             /* parameter hash tables */
    NULL,             /* math functions */
    NULL,             /* ZLE functions (Phase 2) */
    2,                /* number of builtins */
    0, 0, 0, 0,      /* counts for other feature types */
    NULL,             /* hook functions (Phase 2) */
};

/* ── Module lifecycle ─────────────────────────────────────────────────────── */

/**/
int
setup_(UNUSED(Module m))
{
    /* Called when module is loaded (before boot_) */
    return 0;
}

/**/
int
features_(Module m, char ***features)
{
    *features = featuresarray(m, &module_features);
    return 0;
}

/**/
int
enables_(Module m, int **enables)
{
    /* Enable all features */
    return handlefeatures(m, &module_features, enables);
}

/**/
int
boot_(UNUSED(Module m))
{
    /*
     * Called after features are registered.
     * Phase 2: Initialize PTY proxy, load config from ~/.yoconf,
     * register ZLE widgets and hooks.
     */
    zoysh_state.enabled = 1;

    /* Read distro info for system prompt */
    /* Phase 2: yo_detect_distro() */

    return 0;
}

/**/
int
cleanup_(UNUSED(Module m))
{
    /* Called when module is unloaded */
    zoysh_state.enabled = 0;
    /* Phase 2: cleanup PTY proxy, free session memory, etc. */
    return 0;
}

/**/
int
finish_(UNUSED(Module m))
{
    /* Final cleanup */
    return 0;
}
