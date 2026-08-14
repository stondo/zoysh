# Contributing to Zoysh

Thanks for helping improve Zoysh. Bug reports and focused pull requests are welcome.

## Development setup

You need zsh 5.8 or newer, curl, Python 3.8 or newer, and make. Clone the repository and run:

```sh
make check
```

The Phase 1 release is the pure-zsh plugin. Keep changes dependency-light and compatible with a clean zsh session. The C module under `src/` is experimental and is not built by the default target.

## Pull requests

- Add or update a fixture-based test in `tests/test.zsh` for behavior changes.
- Do not put live API keys or network-dependent provider calls in tests.
- Run `make check` and `git diff --check` before submitting.
- Update `README.md` and `CHANGELOG.md` when user-visible behavior changes.
- Preserve Yosh, Fil Pizlo, Epic Games, and other applicable upstream notices in derived work; update `NOTICE` when adding upstream code.
- Keep commits focused and explain compatibility or security tradeoffs in the pull request.

By contributing, you agree that your contribution is licensed under GPL-3.0-only.
