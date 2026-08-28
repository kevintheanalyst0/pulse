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

**Still open:** whether a plain reboot alone can break the session again, or
whether it only happens when both the Windows-native and WSL `claude` installs are
logged into the same account at once.

**Considered but not implemented:** `claude setup-token` generates a long-lived
token that wouldn't depend on an interactive OAuth session staying alive. Could
replace the `.credentials.json` read in `Get-ClaudeUsage` if this keeps recurring.
