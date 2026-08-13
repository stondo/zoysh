# Security policy

## Supported versions

Security fixes are provided for the latest released version of Zoysh.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability reporting for the `stondo/zoysh` repository. Include affected versions, reproduction steps, impact, and any suggested mitigation.

Never include real API keys in a report. Revoke any key that may have been exposed.

## Security model

Zoysh sends prompt context to the API endpoint selected in `~/.yoconf`. Generated commands are untrusted and are only inserted into the zsh prompt; the user remains responsible for reviewing them before execution.
