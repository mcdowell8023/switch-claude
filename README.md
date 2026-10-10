# switch-claude

[中文](README.zh-CN.md)

Keep several [Claude Code](https://docs.anthropic.com/en/docs/claude-code) accounts on one machine and switch between them with one command, without logging in again.

```console
$ switch-claude
Mode: oauth
Active slot: work
Login on record: me@work.example

Slots:
* work       oauth  me@work.example                  ✓ access valid for 6.2h
  personal   oauth  me@home.example                  access expired; refresh CLAIMS 610.0h left (UNVERIFIED)
  ci         token  -                                token stored

$ switch-claude personal
✓ Switched to personal (me@home.example)
```

It is a single bash script. macOS (Keychain) and Linux (credentials file) are both supported.

## Why

Claude Code keeps exactly one login. Switching accounts means `/logout` + `/login` and a browser round trip every time. Copying credential files around does not work either. Every refresh **rotates** the refresh token and voids the old one, so a copy taken yesterday is usually dead.

switch-claude keeps one slot per account and stores rotated credentials back into their slot every time you switch away. It also refuses to overwrite a login that is not stored anywhere, so a working account is never lost by accident.

## Features

- **oauth slots**: the normal `/login` credential (access + refresh token). Switching installs it where Claude Code reads it.
- **token slots**: long-lived tokens from `claude setup-token`, delivered through `CLAUDE_CODE_OAUTH_TOKEN`. Useful on servers and for CI.
- **Never loses a login.** Rotated credentials are written back to their slot before every switch. A live login that belongs to no slot is never overwritten.
- `status --probe` sends one tiny real request per slot and shows the HTTP status and the 5-hour / 7-day usage the API reports. Handy when one account hits its limit.
- Add, rename, remove and re-login slots with commands. No code changes, no hand-edited JSON.
- `backup` / `restore`. `remove` always backs up first.
- A post-switch hook, e.g. to restart a daemon that spawns Claude Code ([example for Paseo](examples/hooks/paseo-restart.sh)).

## Requirements

- bash 3.2+ (the macOS system bash works), `python3`, `awk`, `sed`
- `curl` (only for `status --probe` and switching to a token slot)
- macOS: the `security` command (built in). Linux: nothing else.
- Claude Code, using its default config directory (`CLAUDE_CONFIG_DIR` is not supported).

## Install

```bash
git clone https://github.com/mcdowell8023/switch-claude.git
mkdir -p ~/.local/bin
ln -s "$PWD/switch-claude/bin/switch-claude" ~/.local/bin/switch-claude   # make sure ~/.local/bin is on PATH
switch-claude help
```

## Quick start

### 1. Store the account you are logged in with

```bash
switch-claude add work           # captures the current login, its email and account id
```

### 2. Add a second account

Register it, then log in once:

```bash
switch-claude add personal --email me@home.example
switch-claude login personal     # parks the current login in its slot and logs out
# in Claude Code: /login as me@home.example
switch-claude save               # stores the fresh login in the "personal" slot
```

Without a browser (SSH session), `switch-claude login personal --no-browser` starts `claude auth login` and prints a URL to open elsewhere.

### 3. Switch

```bash
switch-claude work
switch-claude personal
```

New Claude Code sessions use the new account. Sessions that were already running may hold on to the old one; restart them to be sure.

## Token slots

`claude setup-token` creates a token valid for about a year. Claude Code uses it when the environment variable `CLAUDE_CODE_OAUTH_TOKEN` is set, and it takes precedence over any `/login` credential.

```bash
claude setup-token                    # copy the token it prints
switch-claude add ci --token          # paste it at the hidden prompt (or pipe it in)
switch-claude ci                      # probes it, then writes it to the token env file
```

A script cannot change the environment of the shell that started it. So switching to a token slot writes `CLAUDE_CODE_OAUTH_TOKEN=<token>` to an **env file** (default `~/.config/switch-claude/token.env`), and your shells and services read that file:

```bash
# ~/.zshenv or ~/.bashrc
f="${XDG_CONFIG_HOME:-$HOME/.config}/switch-claude/token.env"
[ -r "$f" ] && set -a && . "$f" && set +a
```

```ini
# a systemd unit that runs Claude Code
EnvironmentFile=-%h/.config/switch-claude/token.env
```

Switching back to an oauth slot writes `CLAUDE_CODE_OAUTH_TOKEN=` (empty), which Claude Code treats as unset. New shells then use the oauth slot again, even shells that inherited the old value from a parent like tmux. Shells and services that are already running keep their old environment. Open a new shell, or restart the service (see `post_switch_hook`).

If you already have such an env file, point `token_env_file` at it instead of moving it.

`status` warns when the current shell has a `CLAUDE_CODE_OAUTH_TOKEN` that does not match the env file. It overrides every oauth slot for anything started from that shell.

## Commands

| Command | What it does |
|---|---|
| `switch-claude` / `status [--probe]` | Show slots, the active one, and warnings. `--probe` makes one real request per slot. |
| `switch-claude <name> [--force]` | Switch. `--force` installs fully expired oauth credentials, or skips the token probe. |
| `list` | Names, types and emails only. |
| `add <name>` | Store the current login as a new oauth slot. |
| `add <name> --email <email>` | Register an empty oauth slot to `login` later. |
| `add <name> --token [--email <label>]` | Store a `claude setup-token` token, read from a hidden prompt or stdin. |
| `rename <old> <new>` | Rename a slot. |
| `remove <name>` | Back up, then delete a slot. |
| `login <name> [--no-browser]` | Start a fresh login for a slot; finish it with `save`. |
| `save` | Finish a pending login, or store the active (rotated) credentials back into their slot. |
| `save <name>` | Store the current login into that slot (the email must match). |
| `sync` | Same as `save` when no login is pending. |
| `refresh <name>` / `--all` | Trade an expired access token for a new one with a real request, then switch back. |
| `cancel` | Drop a pending login. |
| `backup` | Snapshot all slots (plaintext; refuses to write inside a git work tree). |
| `restore <dir> [--apply] [name …]` | Put slots back from a snapshot. Dry run unless `--apply`. |

## How it works

| | macOS | Linux |
|---|---|---|
| Active oauth login (read by Claude Code) | Keychain `Claude Code-credentials` / your user name, mirrored to `~/.claude/.credentials.json` | `~/.claude/.credentials.json` |
| Slot secrets | Keychain service `switch-claude`, account = slot name | `~/.config/switch-claude/creds/<name>` (0600) |
| Slot list | `~/.config/switch-claude/slots.conf` | same |

`slots.conf` holds one slot per line: `name type email uuid`. There are no secrets in it, and the commands maintain it. Settings live in `~/.config/switch-claude/config` (see [`examples/config.example`](examples/config.example)): `token_env_file`, `post_switch_hook`, `backup_dir`, `login_args` (e.g. `--sso`) and `probe_model`.

**Rules switch-claude never breaks:**

1. Before anything replaces the active login, the active credential goes back into its own slot. Claude Code refreshes in place, and a refresh voids the copy in the slot.
2. A login that is in no slot and still works is never overwritten; the command stops and says how to keep or drop it. The same holds for a token that only exists in the token env file.
3. `save` refuses credentials whose email does not match the slot, and credentials that are byte-identical to another slot's.
4. An oauth slot whose access token expired is still switchable, because the refresh token gets a new one on the first request. Only when both are expired does it ask for `--force`.
5. An older credential never replaces a newer one in a slot. Rotation only moves the expiry forward, so an active login that expires earlier than its slot's copy is not that slot's latest. This happens when `~/.claude.json` names the wrong account. The switch stops instead.
6. Reads that fail (locked Keychain, permissions) are errors, never "empty". `remove` deletes only after the backup provably holds the slot, and `restore --apply` backs up the slots it replaces.
7. Tokens are accepted only as 40+ characters of `A-Z a-z 0-9 . _ -`, because the env file gets sourced by shells.

## Caveats

- **One machine per slot.** If two machines use the same account and one refreshes, the other's copy is dead. Use a token slot (`claude setup-token`) on the second machine instead.
- `refreshTokenExpiresAt` is only what a token says about itself. A rotated-away token still looks valid locally, so `status` labels it "CLAIMS … UNVERIFIED". Use `status --probe` (or just switch) to find out.
- Credentials are passed to helper processes on stdin, never in environment variables. On macOS the Keychain write passes the secret as an argument to `security`, so another process of **your own user** could see it in `ps` for a moment. `security` cannot read a long value from stdin, and that same user can read the Keychain item directly anyway.
- Backups contain plaintext credentials. Keep `backup_dir` out of git and synced folders.
- `status --probe` and token switches send a real request (max_tokens 8) to `api.anthropic.com`.
- This is an independent tool, not affiliated with Anthropic. It relies on where Claude Code currently stores credentials, which may change.

## Tests

```bash
bash test/switch-claude.test.sh              # every test, once per platform backend
TEST_PLATFORMS=linux bash test/switch-claude.test.sh test_switch_
```

The suite runs inside a throwaway `HOME` with mocked `security`, `claude` and `curl`. It never touches your Keychain, your credentials or the network.

## License

[MIT](LICENSE)
