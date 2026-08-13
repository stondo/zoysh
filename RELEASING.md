# Releasing Zoysh

## Checklist

1. Confirm `ZOYSH_VERSION` and the dated entry in `CHANGELOG.md` match the intended tag.
2. Run `make check` on a clean checkout.
3. Smoke-test one local OpenAI-compatible endpoint and each hosted provider you intend to advertise, using disposable or restricted API keys.
4. Confirm the GitHub Actions Linux and macOS jobs pass.
5. Verify manual and plugin-manager installation in a clean zsh session.
6. Review `git diff --check`, dependency versions, `LICENSE`, `NOTICE`, and the release archive contents.
7. Create an annotated `v0.3.0` tag and publish the matching changelog section as the GitHub release notes.

Do not publish a release from a working tree with uncommitted changes. Never paste live API keys into logs, issues, screenshots, or release notes.

## Announcement draft

> Zoysh 0.3.0 turns natural-language requests into editable zsh commands without executing them. The Phase 1 plugin supports local OpenAI-compatible servers, Anthropic, OpenAI, and other chat-completions providers; keeps bounded session context in memory; and preserves multiline results. It is a single zsh script with curl and Python 3 as its only runtime dependencies. Install it with your zsh plugin manager or source `zoysh.plugin.zsh`, then configure `~/.yoconf`. Review every generated command before running it.
