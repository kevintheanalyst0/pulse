# Troubleshooting

## Claude shows "?" while ChatGPT reads fine

**Symptom:** the tray popup shows real percentages for ChatGPT (session/weekly) but
"?" for Claude in both columns.

**Root cause:** this is not a `Pulse.ps1` bug — `Get-ClaudeUsage` reads
`%USERPROFILE%\.claude\.credentials.json` and calls the right endpoint correctly.
The problem is that the native Windows `claude` CLI's OAuth session itself died: the
saved `accessToken` expired, and the automatic refresh attempt failed server-side
with `Failed to authenticate: OAuth session expired and could not be refreshed`.
That only surfaces when the real CLI is used (`claude -p "..."`) — `claude auth
status` and `claude doctor` just read the locally cached state and never attempt a
refresh, so they'll report "logged in" even while the session is actually dead.

**Working hypothesis (2026-08-27, not fully confirmed):** the same Anthropic account
had an active `claude` session in *two* separate installs at once — native Windows
(`C:\Users\<user>\.local\bin\claude.exe`, the one Pulse reads) and WSL/Ubuntu, each
with its own `.credentials.json`. Refreshing one may rotate/invalidate the other's
refresh token server-side. Ruled out: PowerShell 5 vs PowerShell 7 — both resolve
to the exact same native binary and credentials file, so the shell used to log in
doesn't matter.

**Fix:** open a native Windows terminal (PowerShell or cmd — *not* WSL, which has
its own separate `claude` install and credentials) and run:

```
claude auth login
```

Pulse picks up the refreshed credentials on its own on the next poll (every 5 min,
or "Actualizar ahora" from the tray menu) — no restart needed.

**Confirmed (2026-08-28):** yes, a plain reboot reliably breaks it, and the dual-install
rotation theory above wasn't needed to explain it. Compared the two credential
files' `expiresAt` directly: the Windows-native token issued at 18:23 expired at
02:23 the next day - exactly 8h later, the access token's fixed lifetime. Nothing
on the Windows-native side had invoked `claude` since that login, so nothing
refreshed it. `Get-ClaudeUsage` only ever reads the saved `accessToken` and calls
the usage endpoint directly - it never triggers a refresh, only a real `claude`
invocation does that. Since the PC is off overnight, by the next boot more than 8h
have routinely passed with no native `claude` invocation, so the token is already
dead on the first poll. It reads as "caused by reboot" but the actual trigger is
elapsed idle time past the 8h TTL, which reboot happens to correlate with.

**Tried and rejected:** `claude setup-token` for a long-lived token, to sidestep
the refresh entirely. Generated one and hit `/api/oauth/usage` with it directly -
403, `oauth_scope_insufficient`. `setup-token` sessions only get the
`user:inference` scope; the usage endpoint requires `user:profile`, which that
token flow never grants. Confirmed via direct API test, not from docs.

**Fix (implemented):** `Get-ClaudeUsage` now retries. On a 401 it shells out to
the cheapest possible real invocation (`claude -p "hi" --model haiku`, 30s
timeout) to force the CLI's own legitimate refresh-token exchange - the same
thing manually running `claude` once used to do - then re-reads
`.credentials.json` and retries the usage call once. Gated to once per 20 min so
a real outage (network down, etc.) can't turn into repeated live Claude calls on
every 5-minute poll. `claude auth --help` on the native install confirmed there's
no cheaper `refresh`-only subcommand (`auth` only has `login` / `logout` /
`status`, and `status` just reads cached local state without attempting a
refresh) - a real invocation is the only supported way to force it.
