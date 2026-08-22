# `bin/` — GitHub identity guards

**This repository is always worked on as the GitHub account `cedagova`.**

This machine is logged into more than one GitHub account, and `gh`'s active
account is machine-global shared state that other sessions flip. Relying on
whichever account happens to be active will push as the wrong identity or fail
outright. Nothing here reads that global state — every script pins `cedagova`
explicitly and refuses anything else.

## Scripts

| Script | Purpose |
| --- | --- |
| `setup-identity` | One-time wiring for a fresh clone. Run it first. |
| `gh-personal` | Run `gh` as `cedagova`, whatever the active account is. |
| `git-credential-personal` | Git credential helper; serves a `cedagova` token for `github.com`. |

`../.githooks/pre-push` is the backstop: it blocks any push whose remote is not
a `cedagova`-owned GitHub repo, or where the resolved account is not `cedagova`.

## Fresh clone

Local git config is not cloned, so the hook path and credential helper must be
set per clone or every guard here is silently inert:

```sh
./bin/setup-identity
```

## Rules

- Use `./bin/gh-personal <args>` instead of bare `gh`. It mints a token scoped
  to `cedagova` per invocation, so nothing leaks between calls.
- `gh-personal` refuses `gh auth` and `gh config` on purpose — this repository
  must never mutate machine-wide GitHub CLI state.
- Tokens are read from the `gh` keyring on demand and never written to disk,
  git config, or the environment beyond a single command.
