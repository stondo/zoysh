/*
 * SPDX-License-Identifier: GPL-3.0-only
 * Copyright (C) 2026 Stefano Tondo
 *
 * zoysh.c - native zsh module for zoysh, the zsh port of Yosh.
 *
 * Yosh: https://github.com/pizlonator/yosh
 * Yosh readline-8.2.13/yo.c is Copyright (C) 2026 Epic Games, Inc.
 * The configuration directives, provider defaults, session model, and the
 * multi-step/streaming designs follow Yosh's yo.c; this implementation is
 * an independent port written for zsh. JSON handling uses cJSON (MIT),
 * vendored under src/vendor/cJSON.
 *
 * Module surface:
 *   zoysh-status   print a summary of the loaded configuration
 *   zoysh-call     one streaming completion over curl, speaking the same
 *                  NUL-terminated record protocol as the python helper in
 *                  zoysh.plugin.zsh (P/D/H/L/R/S/B/E/C/Z records)
 *
 * The script plugin bridges to this module with
 *   zstyle ':zoysh:engine' engine module
 * and falls back to the pure-script engine whenever the module is absent.
 * API keys are passed to curl through its in-memory header list and never
 * appear in any argv, mirroring the script engine's fd-backed header source.
 *
 * Ctrl-C cancellation: while zoysh-call runs inside a process substitution
 * of the interactive shell, both processes receive terminal SIGINT. The
 * builtin installs a lightweight handler that flips a flag; curl's progress
 * callback observes the flag and aborts the transfer, the partial output is
 * kept, and a C record plus exit status 130 tell the script engine to print
 * the usual "yo: cancelled" notice. This is the self-pipe idea from yosh's
 * yo.c reduced to a single-threaded builtin.
 */

#include "zoysh.mdh"

#include <curl/curl.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <ctype.h>

#include "cJSON.h"

#define ZOYSH_MODVERSION "0.4.0-module"

/* ─── Configuration ─────────────────────────────────────────────────────── */

typedef struct zoysh_config {
    char provider[64];
    char model[256];
    char base_url[512];
    char api_key[512];
    char conf_path[1024];
    int history_limit;
    int token_budget;
    int max_output_tokens;
    int timeout;
    int streaming;
    int continuation;
    int server_web;
    int scrollback_enabled;
    long scrollback_bytes;
    int scrollback_lines;
} zoysh_config_t;

static void
zoysh_config_defaults(zoysh_config_t *config)
{
    const char *env;

    memset(config, 0, sizeof(*config));
    strlcpy(config->provider, "local", sizeof(config->provider));
    if ((env = getenv("ZOYSH_PROVIDER")) && *env)
        strlcpy(config->provider, env, sizeof(config->provider));
    if ((env = getenv("ZOYSH_MODEL")) && *env)
        strlcpy(config->model, env, sizeof(config->model));
    if ((env = getenv("ZOYSH_BASE_URL")) && *env)
        strlcpy(config->base_url, env, sizeof(config->base_url));
    if ((env = getenv("ZOYSH_API_KEY")) && *env)
        strlcpy(config->api_key, env, sizeof(config->api_key));
    if ((env = getenv("ZOYSH_CONF")) && *env)
        strlcpy(config->conf_path, env, sizeof(config->conf_path));
    else
        snprintf(config->conf_path, sizeof(config->conf_path),
                 "%s/.yoconf", getenv("HOME") ? getenv("HOME") : "");

    config->history_limit = 10;
    if ((env = getenv("ZOYSH_HISTORY_LIMIT")) && atoi(env) > 0)
        config->history_limit = atoi(env);
    config->token_budget = 4096;
    if ((env = getenv("ZOYSH_TOKEN_BUDGET")) && atoi(env) > 0)
        config->token_budget = atoi(env);
    config->max_output_tokens = 4096;
    if ((env = getenv("ZOYSH_MAX_OUTPUT_TOKENS")) && atoi(env) > 0)
        config->max_output_tokens = atoi(env);
    config->timeout = 30;
    if ((env = getenv("ZOYSH_TIMEOUT")) && atoi(env) > 0)
        config->timeout = atoi(env);
    config->streaming = 1;
    if ((env = getenv("ZOYSH_STREAMING")) && *env)
        config->streaming = atoi(env);
    config->continuation = 0;
    if ((env = getenv("ZOYSH_CONTINUATION")) && *env)
        config->continuation = atoi(env);
    config->server_web = 1;
    if ((env = getenv("ZOYSH_SERVER_WEB")) && *env)
        config->server_web = atoi(env);
    config->scrollback_enabled = 0;
    config->scrollback_bytes = 1048576;
    config->scrollback_lines = 1000;
}

/* Trim leading and trailing whitespace in place. */
static void
zoysh_trim(char *text)
{
    size_t len;

    while (*text && isspace((unsigned char) *text))
        memmove(text, text + 1, strlen(text));
    len = strlen(text);
    while (len && isspace((unsigned char) text[len - 1]))
        text[--len] = '\0';
}

/* Strip one pair of matching surrounding quotes in place. */
static void
zoysh_unquote(char *text)
{
    size_t len = strlen(text);

    if (len >= 2 &&
        ((text[0] == '"' && text[len - 1] == '"') ||
         (text[0] == '\'' && text[len - 1] == '\''))) {
        text[len - 1] = '\0';
        memmove(text, text + 1, len);
    }
}

/*
 * Parse the zoysh/yosh config file. Recognized directives mirror the script
 * engine; display directives are consumed for compatibility but only change
 * module behavior where noted. Validation also mirrors the script engine.
 */
static int
zoysh_config_load(zoysh_config_t *config)
{
    FILE *handle;
    char line[2048];

    handle = fopen(config->conf_path, "r");
    if (!handle)
        return 0;
    while (fgets(line, sizeof(line), handle)) {
        char key[64];
        char *value;
        size_t len = strlen(line);

        while (len && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        zoysh_trim(line);
        if (!line[0] || line[0] == '#')
            continue;
        if (sscanf(line, "%63s", key) != 1)
            continue;
        if (strlen(key) >= strlen(line))
            continue;
        value = line + strlen(key);
        zoysh_trim(value);
        zoysh_unquote(value);

        if (!strcmp(key, "provider"))
            strlcpy(config->provider, value, sizeof(config->provider));
        else if (!strcmp(key, "model"))
            strlcpy(config->model, value, sizeof(config->model));
        else if (!strcmp(key, "base_url"))
            strlcpy(config->base_url, value, sizeof(config->base_url));
        else if (!strcmp(key, "key"))
            strlcpy(config->api_key, value, sizeof(config->api_key));
        else if (!strcmp(key, "history_limit"))
            config->history_limit = atoi(value);
        else if (!strcmp(key, "token_budget"))
            config->token_budget = atoi(value);
        else if (!strcmp(key, "max_output_tokens"))
            config->max_output_tokens = atoi(value);
        else if (!strcmp(key, "timeout"))
            config->timeout = atoi(value);
        else if (!strcmp(key, "streaming"))
            config->streaming = atoi(value);
        else if (!strcmp(key, "continuation"))
            config->continuation = atoi(value);
        else if (!strcmp(key, "server_web"))
            config->server_web = atoi(value);
        else if (!strcmp(key, "scrollback_enabled"))
            config->scrollback_enabled = atoi(value);
        else if (!strcmp(key, "scrollback_bytes"))
            config->scrollback_bytes = atol(value);
        else if (!strcmp(key, "scrollback_lines"))
            config->scrollback_lines = atoi(value);
        /*
         * chat_prefix, color_prefix, and the other display directives are
         * rendered by the script engine; accepted here for compatibility.
         */
    }
    fclose(handle);

    if (config->history_limit < 1 || config->history_limit > 1000)
        config->history_limit = 10;
    if (config->token_budget < 100 || config->token_budget > 1000000)
        config->token_budget = 4096;
    if (config->max_output_tokens < 1 || config->max_output_tokens > 100000)
        config->max_output_tokens = 4096;
    if (config->timeout < 1 || config->timeout > 600)
        config->timeout = 30;
    if (config->streaming != 0 && config->streaming != 1)
        config->streaming = 1;
    if (config->continuation != 0 && config->continuation != 1)
        config->continuation = 0;
    if (config->server_web != 0 && config->server_web != 1)
        config->server_web = 1;
    return 1;
}

/* Default endpoint per provider; port of the script's _zoysh_api_endpoint. */
static void
zoysh_api_endpoint(const zoysh_config_t *config, char *buffer, size_t size)
{
    const char *base;
    const char *suffix;
    const char *defbase = "";
    size_t len;

    if (config->base_url[0]) {
        base = config->base_url;
    } else if (!strcmp(config->provider, "anthropic")) {
        defbase = "https://api.anthropic.com/v1"; base = defbase;
    } else if (!strcmp(config->provider, "openai")) {
        defbase = "https://api.openai.com/v1"; base = defbase;
    } else if (!strcmp(config->provider, "openrouter")) {
        defbase = "https://openrouter.ai/api/v1"; base = defbase;
    } else if (!strcmp(config->provider, "kimi")) {
        defbase = "https://api.moonshot.ai/v1"; base = defbase;
    } else if (!strcmp(config->provider, "deepseek")) {
        defbase = "https://api.deepseek.com"; base = defbase;
    } else if (!strcmp(config->provider, "qwen")) {
        defbase = "https://dashscope.aliyuncs.com/compatible-mode/v1"; base = defbase;
    } else if (!strcmp(config->provider, "zai")) {
        defbase = "https://api.z.ai/api/paas/v4"; base = defbase;
    } else {
        defbase = "http://127.0.0.1:8001/v1"; base = defbase;
    }

    if (!strcmp(config->provider, "anthropic"))
        suffix = "/messages";
    else if (!strcmp(config->provider, "openai"))
        suffix = "/responses";
    else
        suffix = "/chat/completions";

    len = strlen(base);
    while (len && base[len - 1] == '/')
        len--;
    snprintf(buffer, size, "%.*s%s", (int) len, base, suffix);
}

/* ─── Streaming client ──────────────────────────────────────────────────── */

#define ZOYSH_OPEN_TAG "<think>"
#define ZOYSH_CLOSE_TAG "</think>"

typedef struct zoysh_stream {
    zoysh_config_t config;
    char mode;                 /* '\0' undetermined, 's' sse, 'b' body */
    char *body;
    size_t body_len;
    char *sse_text;
    size_t sse_len;
    char line[8192];
    size_t line_len;
    long status;
    char error[512];
    int cancelled;

    char think_state;          /* 'n' normal, 't' think */
    char carry[16];
    int lines;
    int col;
    int cols;
    int visible;

    char *raw;
    size_t raw_len;
    char finish_reason[32];
    char stop_reason[32];
    char resp_status[32];
} zoysh_stream_t;

static volatile sig_atomic_t zoysh_cancel_flag = 0;

/*
 * Records are <type-char><payload><NUL> on stdout, matching the python
 * streaming helper: P pid, D visible delta, H heartbeat, L lines<US>col,
 * R synthesized response, S status, B raw body, E error, C cancelled, Z end.
 * NUL bytes never occur inside payloads because deltas are sanitized.
 */
static int
zoysh_emit(char type, const char *payload)
{
    char head[2];
    int ok;

    head[0] = type;
    ok = fwrite(head, 1, 1, stdout) == 1;
    if (payload && *payload)
        ok = fwrite(payload, 1, strlen(payload), stdout) == strlen(payload) && ok;
    head[0] = '\0';
    ok = fwrite(head, 1, 1, stdout) == 1 && ok;
    fflush(stdout);
    return ok;
}

static char *
zoysh_grow(char *buffer, size_t *len, const char *text)
{
    size_t add = strlen(text);
    char *grown = (char *) realloc(buffer, *len + add + 1);

    if (!grown)
        return buffer;
    memcpy(grown + *len, text, add);
    *len += add;
    grown[*len] = '\0';
    return grown;
}

/* Strip unsafe C0/DEL controls; UTF-8 passes through, bidi controls drop. */
static void
zoysh_sanitize(char *text)
{
    unsigned char *read = (unsigned char *) text;
    unsigned char *write = read;

    while (*read) {
        unsigned char ch = *read;

        if (ch < 128) {
            if (ch == '\n' || ch == '\t' || (ch >= 32 && ch != 127))
                *write++ = ch;
            read++;
            continue;
        }
        /* Multi-byte UTF-8: drop the bidi control block introducers. */
        if (ch == 0xE2 && read[1] == 0x80) {
            unsigned char third = read[2];
            if (third == 0xAA || third == 0xAB || third == 0xAC ||
                third == 0xAD || third == 0xAE || third == 0xAF ||
                third == 0x8E || third == 0x8F) {
                read += 3;
                continue;
            }
        }
        if (ch == 0xE2 && read[1] == 0x81 && read[2] >= 0xA6 &&
            read[2] <= 0xA9) {
            read += 3;
            continue;
        }
        if (ch == 0xD9 && read[1] == 0x9C) {
            read += 2;
            continue;
        }
        /* Keep any other well-formed sequence byte for byte. */
        {
            size_t step = 1;
            if ((ch & 0xE0) == 0xC0)
                step = 2;
            else if ((ch & 0xF0) == 0xE0)
                step = 3;
            else if ((ch & 0xF8) == 0xF0)
                step = 4;
            while (step-- && *read)
                *write++ = *read++;
        }
    }
    *write = '\0';
}

/* Approximate terminal cell width; mirrors the helper's east-asian logic. */
static int
zoysh_char_width(const char *text, size_t *advance)
{
    wchar_t wide;
    mbstate_t state;
    size_t used;

    memset(&state, 0, sizeof(state));
    used = mbrtowc(&wide, text, MB_CUR_MAX, &state);
    if (used == (size_t) -1 || used == (size_t) -2 || used == 0) {
        *advance = 1;
        return 1;
    }
    *advance = used;
    if ((wide >= 0x1100 && wide <= 0x115F) ||
        (wide >= 0x2E80 && wide <= 0xA4CF) ||
        (wide >= 0xAC00 && wide <= 0xD7A3) ||
        (wide >= 0xF900 && wide <= 0xFAFF) ||
        (wide >= 0xFE30 && wide <= 0xFE6F) ||
        (wide >= 0xFF00 && wide <= 0xFF60) ||
        (wide >= 0xFFE0 && wide <= 0xFFE6) ||
        (wide >= 0x20000 && wide <= 0x3FFFD))
        return 2;
    return 1;
}

static void
zoysh_advance(zoysh_stream_t *stream, const char *text)
{
    const char *cursor = text;

    while (*cursor) {
        size_t used = 1;
        int width;

        if (*cursor == '\n') {
            stream->lines++;
            stream->col = 0;
            cursor++;
            continue;
        }
        width = zoysh_char_width(cursor, &used);
        if (*cursor == '\t')
            stream->col = (stream->col / 8 + 1) * 8;
        else
            stream->col += width;
        if (stream->col >= stream->cols) {
            stream->lines++;
            stream->col = 0;
        }
        cursor += used;
    }
}

/* Longest suffix of text that is a proper prefix of tag. */
static int
zoysh_suffix_overlap(const char *text, const char *tag)
{
    size_t tlen = strlen(text);
    size_t taglen = strlen(tag);
    size_t limit = tlen < taglen - 1 ? tlen : taglen - 1;
    size_t size;

    for (size = limit; size > 0; size--) {
        if (!strncmp(text + tlen - size, tag, size))
            return (int) size;
    }
    return 0;
}

/*
 * Incremental <think> suppression with a carry buffer for tags split across
 * chunk boundaries. Returns freshly malloc'd visible text ("" when all of
 * the input was suppressed); caller frees.
 */
static char *
zoysh_feed(zoysh_stream_t *stream, const char *text)
{
    size_t buflen = strlen(stream->carry) + strlen(text);
    char *buffer = (char *) malloc(buflen + 1);
    char *out;
    size_t i, blen;
    const char *tag;
    const char *found;

    if (!buffer)
        return NULL;
    strcpy(buffer, stream->carry);
    strcat(buffer, text);
    stream->carry[0] = '\0';

    out = (char *) calloc(buflen + 1, 1);
    if (!out) {
        free(buffer);
        return NULL;
    }
    i = 0;
    blen = strlen(buffer);
    while (i < blen) {
        tag = stream->think_state == 't' ? ZOYSH_CLOSE_TAG : ZOYSH_OPEN_TAG;
        found = strstr(buffer + i, tag);
        if (!found) {
            int keep = zoysh_suffix_overlap(buffer + i, tag);
            size_t cut = strlen(buffer + i) - (size_t) keep;
            strncat(out, buffer + i, cut);
            strlcpy(stream->carry, buffer + i + cut, sizeof(stream->carry));
            break;
        }
        strncat(out, buffer + i, (size_t) (found - (buffer + i)));
        i = (size_t) (found - buffer) + strlen(tag);
        stream->think_state = stream->think_state == 't' ? 'n' : 't';
        while (i < blen && (buffer[i] == ' ' || buffer[i] == '\t' ||
                            buffer[i] == '\r' || buffer[i] == '\n'))
            i++;
    }
    free(buffer);
    return out;
}

static void
zoysh_handle_text(zoysh_stream_t *stream, const char *text)
{
    char *clean;
    char *visible;

    if (!text || !*text)
        return;
    stream->raw = zoysh_grow(stream->raw, &stream->raw_len, text);
    clean = (char *) malloc(strlen(text) + 1);
    if (!clean)
        return;
    strcpy(clean, text);
    zoysh_sanitize(clean);
    visible = zoysh_feed(stream, clean);
    free(clean);
    if (!visible)
        return;
    if (*visible) {
        zoysh_advance(stream, visible);
        zoysh_emit('D', visible);
        stream->visible = 1;
    }
    free(visible);
}

static void
zoysh_set_string(char *target, size_t size, const cJSON *item)
{
    if (cJSON_IsString(item) && item->valuestring && item->valuestring[0])
        strlcpy(target, item->valuestring, size);
}

static const char *
zoysh_error_message(const cJSON *error)
{
    const cJSON *message;

    if (!error)
        return "unknown error";
    message = cJSON_GetObjectItem(error, "message");
    if (cJSON_IsString(message) && message->valuestring)
        return message->valuestring;
    return "unknown error";
}

/* Extract provider-specific deltas and finish flags from one SSE chunk. */
static void
zoysh_handle_sse_chunk(zoysh_stream_t *stream, const char *payload)
{
    const zoysh_config_t *config = &stream->config;
    cJSON *chunk;
    cJSON *item;
    const char *otype = NULL;

    chunk = cJSON_Parse(payload);
    if (!chunk || !cJSON_IsObject(chunk)) {
        if (chunk)
            cJSON_Delete(chunk);
        zoysh_emit('H', "");
        return;
    }
    item = cJSON_GetObjectItem(chunk, "type");
    if (cJSON_IsString(item))
        otype = item->valuestring;

    if (!strcmp(config->provider, "anthropic")) {
        if (otype && !strcmp(otype, "content_block_delta")) {
            cJSON *delta = cJSON_GetObjectItem(chunk, "delta");
            cJSON *text = delta ? cJSON_GetObjectItem(delta, "text") : NULL;
            if (cJSON_IsString(text))
                zoysh_handle_text(stream, text->valuestring);
            else
                zoysh_emit('H', "");
        } else if (otype && !strcmp(otype, "message_delta")) {
            cJSON *delta = cJSON_GetObjectItem(chunk, "delta");
            zoysh_set_string(stream->stop_reason, sizeof(stream->stop_reason),
                             delta ? cJSON_GetObjectItem(delta, "stop_reason")
                                   : NULL);
            zoysh_emit('H', "");
        } else if (otype && !strcmp(otype, "error")) {
            snprintf(stream->error, sizeof(stream->error), "API error: %s",
                     zoysh_error_message(cJSON_GetObjectItem(chunk, "error")));
        } else {
            zoysh_emit('H', "");
        }
    } else if (!strcmp(config->provider, "openai")) {
        if (otype && !strcmp(otype, "response.output_text.delta")) {
            cJSON *delta = cJSON_GetObjectItem(chunk, "delta");
            if (cJSON_IsString(delta))
                zoysh_handle_text(stream, delta->valuestring);
            else
                zoysh_emit('H', "");
        } else if (otype && !strcmp(otype, "response.completed")) {
            zoysh_set_string(stream->resp_status, sizeof(stream->resp_status),
                             item);
            zoysh_emit('H', "");
        } else if (otype && !strcmp(otype, "response.incomplete")) {
            zoysh_set_string(stream->resp_status, sizeof(stream->resp_status),
                             item);
            zoysh_emit('H', "");
        } else if ((otype && !strcmp(otype, "error")) ||
                   cJSON_GetObjectItem(chunk, "error")) {
            snprintf(stream->error, sizeof(stream->error), "API error: %s",
                     zoysh_error_message(cJSON_GetObjectItem(chunk, "error")));
        } else {
            zoysh_emit('H', "");
        }
    } else {
        cJSON *choices = cJSON_GetObjectItem(chunk, "choices");
        cJSON *choice;

        if (cJSON_IsArray(choices) && cJSON_GetArraySize(choices) > 0 &&
            (choice = cJSON_GetArrayItem(choices, 0)) &&
            cJSON_IsObject(choice)) {
            cJSON *delta = cJSON_GetObjectItem(choice, "delta");
            cJSON *text = delta ? cJSON_GetObjectItem(delta, "content") : NULL;
            cJSON *finish = cJSON_GetObjectItem(choice, "finish_reason");

            if (cJSON_IsString(text) && text->valuestring[0])
                zoysh_handle_text(stream, text->valuestring);
            else
                zoysh_emit('H', "");
            zoysh_set_string(stream->finish_reason,
                             sizeof(stream->finish_reason), finish);
        } else {
            zoysh_emit('H', "");
        }
    }
    cJSON_Delete(chunk);
}

static void
zoysh_process_line(zoysh_stream_t *stream, const char *line)
{
    const char *payload;

    if (stream->mode == 'b') {
        stream->body = zoysh_grow(stream->body, &stream->body_len, line);
        stream->body = zoysh_grow(stream->body, &stream->body_len, "\n");
        return;
    }
    if (!line[0] || line[0] == ':' || !strncmp(line, "event:", 6) ||
        !strncmp(line, "retry:", 6)) {
        if (stream->mode == 's')
            zoysh_emit('H', "");
        return;
    }
    if (strncmp(line, "data:", 5)) {
        stream->mode = 'b';
        stream->body = zoysh_grow(stream->body, &stream->body_len, line);
        stream->body = zoysh_grow(stream->body, &stream->body_len, "\n");
        return;
    }
    stream->mode = 's';
    stream->sse_text = zoysh_grow(stream->sse_text, &stream->sse_len, line);
    stream->sse_text = zoysh_grow(stream->sse_text, &stream->sse_len, "\n");
    payload = line + 5;
    if (*payload == ' ')
        payload++;
    if (!strcmp(payload, "[DONE]"))
        return;
    if (stream->error[0])
        return;
    zoysh_handle_sse_chunk(stream, payload);
}

static size_t
zoysh_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    zoysh_stream_t *stream = (zoysh_stream_t *) userdata;
    size_t total = size * nmemb;
    size_t i;

    for (i = 0; i < total; i++) {
        if (ptr[i] == '\n') {
            stream->line[stream->line_len] = '\0';
            if (stream->line_len &&
                stream->line[stream->line_len - 1] == '\r')
                stream->line[stream->line_len - 1] = '\0';
            zoysh_process_line(stream, stream->line);
            stream->line_len = 0;
        } else if (stream->line_len + 1 < sizeof(stream->line)) {
            stream->line[stream->line_len++] = ptr[i];
        }
    }
    return total;
}

static size_t
zoysh_header_cb(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    zoysh_stream_t *stream = (zoysh_stream_t *) userdata;
    size_t total = size * nmemb;
    const char *cursor;

    if (total > 5 && !strncmp(ptr, "HTTP/", 5)) {
        cursor = (const char *) ptr + 5;
        while (cursor < (const char *) ptr + total &&
               *cursor && !isspace((unsigned char) *cursor))
            cursor++;
        while (cursor < (const char *) ptr + total &&
               isspace((unsigned char) *cursor))
            cursor++;
        {
            long status = strtol(cursor, NULL, 10);
            if (status > 0)
                stream->status = status;
        }
    }
    return total;
}

static int
zoysh_progress_cb(void *userdata, curl_off_t dltotal, curl_off_t dlnow,
                  curl_off_t ultotal, curl_off_t ulnow)
{
    (void) userdata;
    (void) dltotal;
    (void) dlnow;
    (void) ultotal;
    (void) ulnow;
    return zoysh_cancel_flag ? 1 : 0;
}

static void
zoysh_on_cancel(int signo)
{
    (void) signo;
    zoysh_cancel_flag = 1;
}

static cJSON *
zoysh_synthesize(const zoysh_stream_t *stream)
{
    const zoysh_config_t *config = &stream->config;
    const char *raw = stream->raw ? stream->raw : "";
    cJSON *synth;
    cJSON *choices;
    cJSON *choice;
    cJSON *message;
    cJSON *output;
    cJSON *content;
    cJSON *block;

    synth = cJSON_CreateObject();
    if (!synth)
        return NULL;
    if (!strcmp(config->provider, "anthropic")) {
        content = cJSON_CreateArray();
        block = cJSON_CreateObject();
        cJSON_AddStringToObject(block, "type", "text");
        cJSON_AddStringToObject(block, "text", raw);
        cJSON_AddItemToArray(content, block);
        cJSON_AddItemToObject(synth, "content", content);
        cJSON_AddStringToObject(synth, "stop_reason",
                                stream->stop_reason[0] ?
                                stream->stop_reason : "end_turn");
    } else if (!strcmp(config->provider, "openai")) {
        output = cJSON_CreateArray();
        message = cJSON_CreateObject();
        content = cJSON_CreateArray();
        block = cJSON_CreateObject();
        cJSON_AddStringToObject(block, "type", "output_text");
        cJSON_AddStringToObject(block, "text", raw);
        cJSON_AddItemToArray(content, block);
        cJSON_AddItemToObject(message, "content", content);
        cJSON_AddStringToObject(message, "type", "message");
        cJSON_AddItemToArray(output, message);
        cJSON_AddItemToObject(synth, "output", output);
        cJSON_AddStringToObject(synth, "status",
                                stream->resp_status[0] ?
                                stream->resp_status : "completed");
    } else {
        choices = cJSON_CreateArray();
        choice = cJSON_CreateObject();
        message = cJSON_CreateObject();
        cJSON_AddStringToObject(message, "content", raw);
        cJSON_AddItemToObject(choice, "message", message);
        cJSON_AddStringToObject(choice, "finish_reason",
                                stream->finish_reason[0] ?
                                stream->finish_reason : "stop");
        cJSON_AddItemToArray(choices, choice);
        cJSON_AddItemToObject(synth, "choices", choices);
    }
    return synth;
}

static void
zoysh_finalize(zoysh_stream_t *stream, CURLcode code)
{
    char record[128];
    cJSON *synth;
    char *printed;

    if (stream->cancelled || zoysh_cancel_flag) {
        zoysh_emit('C', "cancelled");
        zoysh_emit('Z', "");
        return;
    }
    if (code != CURLE_OK && !stream->raw_len && stream->mode != 'b' &&
        !stream->error[0]) {
        snprintf(stream->error, sizeof(stream->error),
                 "request failed (curl exit %d)", (int) code);
    }
    if (stream->error[0]) {
        zoysh_emit('E', stream->error);
        zoysh_emit('Z', "");
        return;
    }
    if (stream->mode != 's') {
        snprintf(record, sizeof(record), "%ld", stream->status);
        zoysh_emit('S', record);
        zoysh_emit('B', stream->body ? stream->body : "");
        zoysh_emit('Z', "");
        return;
    }
    if (stream->status && (stream->status < 200 || stream->status >= 300)) {
        snprintf(record, sizeof(record), "%ld", stream->status);
        zoysh_emit('S', record);
        zoysh_emit('B', stream->sse_text ? stream->sse_text : "");
        zoysh_emit('Z', "");
        return;
    }
    synth = zoysh_synthesize(stream);
    snprintf(record, sizeof(record), "%d\x1f%d", stream->lines, stream->col);
    zoysh_emit('L', record);
    if (synth) {
        printed = cJSON_PrintUnformatted(synth);
        if (printed) {
            zoysh_emit('R', printed);
            cJSON_free(printed);
        }
        cJSON_Delete(synth);
    }
    zoysh_emit('Z', "");
}

/* ─── builtin: zoysh-call ───────────────────────────────────────────────── */

/**/
static int
bin_zoysh_call(char *name, char **argv, UNUSED(Options ops), UNUSED(int func))
{
    zoysh_stream_t *stream;
    CURL *curl = NULL;
    CURLcode code = CURLE_FAILED_INIT;
    struct curl_slist *headers = NULL;
    char endpoint[1024];
    char header_text[1024];
    char usertoken[64];
    const char *env;
    struct sigaction cancel_action;
    struct sigaction old_int;
    struct sigaction old_term;
    char *body = NULL;
    size_t body_len = 0;
    int status = 0;
    char pidbuf[32];

    if (!argv[0]) {
        zwarnnam(name, "usage: zoysh-call <endpoint>");
        return 1;
    }

    stream = (zoysh_stream_t *) calloc(1, sizeof(*stream));
    if (!stream)
        return 1;
    zoysh_config_defaults(&stream->config);
    zoysh_config_load(&stream->config);
    strlcpy(endpoint, argv[0], sizeof(endpoint));
    stream->cols = 80;
    env = getenv("COLUMNS");
    if (env && atoi(env) >= 10)
        stream->cols = atoi(env);
    stream->think_state = 'n';

    snprintf(pidbuf, sizeof(pidbuf), "%ld", (long) getpid());
    zoysh_emit('P', pidbuf);

    body = (char *) malloc(8192);
    if (body) {
        size_t capacity = 8192;
        for (;;) {
            size_t got = fread(body + body_len, 1, capacity - body_len, stdin);
            body_len += got;
            if (body_len < capacity)
                break;
            {
                char *grown = (char *) realloc(body, capacity * 2);
                if (!grown)
                    break;
                body = grown;
                capacity *= 2;
            }
        }
        body[body_len] = '\0';
    }

    if (!body) {
        zoysh_emit('E', "failed to read request body");
        zoysh_emit('Z', "");
        status = 1;
        goto done;
    }

    curl_global_init(CURL_GLOBAL_DEFAULT);
    curl = curl_easy_init();
    if (!curl) {
        zoysh_emit('E', "failed to initialize curl");
        zoysh_emit('Z', "");
        status = 1;
        goto done;
    }

    /* Auth headers live in curl's in-memory list, never in any argv. */
    if (!strcmp(stream->config.provider, "anthropic")) {
        snprintf(header_text, sizeof(header_text),
                 "x-api-key: %s", stream->config.api_key);
        headers = curl_slist_append(headers, header_text);
        headers = curl_slist_append(headers, "anthropic-version: 2023-06-01");
        if (stream->config.server_web && (env = getenv("ZWEB")) &&
            !strcmp(env, "1"))
            headers = curl_slist_append(headers,
                                        "anthropic-beta: web-fetch-2025-09-10");
    } else {
        snprintf(header_text, sizeof(header_text),
                 "Authorization: Bearer %s", stream->config.api_key);
        headers = curl_slist_append(headers, header_text);
    }
    headers = curl_slist_append(headers, "Content-Type: application/json");

    snprintf(usertoken, sizeof(usertoken), "zoysh/%s", ZOYSH_MODVERSION);

    zoysh_cancel_flag = 0;
    memset(&cancel_action, 0, sizeof(cancel_action));
    cancel_action.sa_handler = zoysh_on_cancel;
    sigaction(SIGINT, &cancel_action, &old_int);
    sigaction(SIGTERM, &cancel_action, &old_term);

    curl_easy_setopt(curl, CURLOPT_URL, endpoint);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long) body_len);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, usertoken);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, zoysh_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, stream);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, zoysh_header_cb);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, stream);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, zoysh_progress_cb);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, stream);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);

    code = curl_easy_perform(curl);

    sigaction(SIGINT, &old_int, NULL);
    sigaction(SIGTERM, &old_term, NULL);

    if (code == CURLE_ABORTED_BY_CALLBACK)
        stream->cancelled = 1;

    /* Flush a trailing line not terminated by a newline. */
    if (stream->line_len) {
        stream->line[stream->line_len] = '\0';
        zoysh_process_line(stream, stream->line);
        stream->line_len = 0;
    }

    zoysh_finalize(stream, code);
    if (stream->cancelled)
        status = 130;

done:
    curl_easy_cleanup(curl);
    curl_slist_free_all(headers);
    curl_global_cleanup();
    free(body);
    free(stream->body);
    free(stream->sse_text);
    free(stream->raw);
    free(stream);
    return status;
}

/* ─── builtin: zoysh-status ─────────────────────────────────────────────── */

/**/
static int
bin_zoysh_status(UNUSED(char *name), UNUSED(char **argv),
                 UNUSED(Options ops), UNUSED(int func))
{
    zoysh_config_t config;
    char endpoint[1024];
    int found;

    zoysh_config_defaults(&config);
    found = zoysh_config_load(&config);
    zoysh_api_endpoint(&config, endpoint, sizeof(endpoint));

    printf("zoysh-module %s\n", ZOYSH_MODVERSION);
    printf("config %s%s\n", config.conf_path, found ? "" : " (not found)");
    printf("provider %s\n", config.provider);
    printf("model %s\n", config.model[0] ? config.model : "(auto-detect)");
    printf("endpoint %s\n", endpoint);
    printf("timeout %ds streaming %d continuation %d\n",
           config.timeout, config.streaming, config.continuation);
    printf("engine module\n");
    return 0;
}

/* ─── module setup ──────────────────────────────────────────────────────── */

#define ZOYSH_BUILTIN_COUNT 2

/*
 * The builtin table is cloned onto the heap at setup time, names included.
 * Some zsh builds free module builtin nodes (struct and name) through the
 * hash table's freenode hook on unload; keeping everything in heap memory
 * makes those frees valid instead of corrupting the allocator when it
 * touches the module's static data.
 */
static struct builtin *bintab;
static struct features module_features;

/**/
int
setup_(UNUSED(Module m))
{
    static const struct builtin source[] = {
        BUILTIN("zoysh-status", 0, bin_zoysh_status, 0, 0, 0, "", NULL),
        BUILTIN("zoysh-call", 0, bin_zoysh_call, 1, 1, 0, "", NULL),
    };
    int i;

    bintab = (struct builtin *) zshcalloc(sizeof(source));
    if (!bintab)
        return 1;
    memcpy(bintab, source, sizeof(source));
    for (i = 0; i < ZOYSH_BUILTIN_COUNT; i++)
        bintab[i].node.nam = ztrdup(source[i].node.nam);
    memset(&module_features, 0, sizeof(module_features));
    module_features.bn_list = bintab;
    module_features.bn_size = ZOYSH_BUILTIN_COUNT;
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
    return handlefeatures(m, &module_features, enables);
}

/**/
int
boot_(UNUSED(Module m))
{
    return 0;
}

/**/
int
cleanup_(Module m)
{
    /* Deregister every feature (removes our builtins from the hash table)
       before the module code is unmapped; mirrors zsh's in-tree modules. */
    return setfeatureenables(m, &module_features, NULL);
}

/**/
int
finish_(UNUSED(Module m))
{
    return 0;
}

/*
 * Some vendors (for example Fedora) build zsh with DYNAMIC_NAME_CLASH_OK,
 * where the module loader looks up the plain entry point names instead of
 * the name-mangled ones. Export both spellings so the module loads on both
 * build flavors.
 */
#undef setup_
#undef features_
#undef enables_
#undef boot_
#undef cleanup_
#undef finish_

/**/
int
setup_(Module m)
{
    return setup_zshQszoysh(m);
}

/**/
int
features_(Module m, char ***features)
{
    return features_zshQszoysh(m, features);
}

/**/
int
enables_(Module m, int **enables)
{
    return enables_zshQszoysh(m, enables);
}

/**/
int
boot_(Module m)
{
    return boot_zshQszoysh(m);
}

/**/
int
cleanup_(Module m)
{
    return cleanup_zshQszoysh(m);
}

/**/
int
finish_(Module m)
{
    return finish_zshQszoysh(m);
}
