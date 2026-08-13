# Releasing Zoysh

## Checklist

1. Confirm `ZOYSH_VERSION` and the dated entry in `CHANGELOG.md` match the intended tag.
2. Run `make check` on a clean checkout.
3. Smoke-test one local OpenAI-compatible endpoint and every hosted provider for which release credentials are available; record uncredentialed providers as protocol-tested only.
4. Confirm the GitHub Actions Linux and macOS jobs pass.
5. Verify manual and plugin-manager installation in a clean zsh session.
6. Review `git diff --check`, dependency versions, `LICENSE`, `NOTICE`, and the release archive contents.
7. Create an annotated tag matching `ZOYSH_VERSION` and publish the matching changelog section as the GitHub release notes.

Do not publish a release from a working tree with uncommitted changes. Never paste live API keys into logs, issues, screenshots, or release notes.

## Announcement draft

> Zoysh 0.3.0 brings `yo <natural language>` to zsh as a lightweight plugin. It detects the model loaded in your local OpenAI-compatible server, turns requests into editable commands without executing them, and renders inline answers with terminal-friendly Markdown. It also supports Anthropic, OpenAI, Kimi, DeepSeek, Qwen, and z.ai, bounded session memory, live config reloads, and optional hosted web search. Install it with your zsh plugin manager or source `zoysh.plugin.zsh`; then review every generated command before running it.
