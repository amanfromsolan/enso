# Agent session persistence (cmux-style resume)

Design for issue #32's goal — an agent's conversation survives app quit — via native
agent-CLI resume rather than PTY persistence. Nothing runs while the app is closed
("quit means stop" is automatic and force-quit-proof). On relaunch, a tab whose agent
was running at quit re-runs the agent's own resume command with the session ID we
recorded, and the agent is back with full history.

Verified against: claude 2.1.208 (local), codex-cli 0.144.1 (local), cmux wrappers
(vendored at `references/cmux/Resources/`), ghostty shell-integration source.

## Architecture

Three layers, deliberately modular so each agent CLI is a plug-in:

1. **Shim layer (shell)** — one shared shim dir `~/Library/Application Support/Enso/shims/bin/`
   containing wrapper scripts named `claude`, `codex`, plus a shared `enso-hook-relay`.
   Rewritten (versioned) on every app launch by `AgentShimInstaller`. NOT under TMPDIR
   (macOS purges /var/folders temp files not accessed for ~3 days).
2. **Recording layer (JSONL map files)** — wrappers and hook relays append events to
   `~/Library/Application Support/Enso/agent-sessions/<tab-uuid>.jsonl`. The app never
   needs a socket; everything is local-file, fire-and-forget, no IPC hang risk.
3. **Restore layer (Swift)** — at launch, `AgentSessionStore` compacts each map file to
   the latest session per tab and decides restorability; `GhosttySurfaceManager` feeds
   the resume command to the new surface via libghostty `initial_input`.

The `TerminalSession` model is untouched — the map lives beside `state.json`, keyed by
the tab's existing stable UUID.

### Spawn-time environment (GhosttySurfaceView)

Extend `createSurface` to set on `ghostty_surface_config_s` (all fields exist in our
built GhosttyKit — `env_vars`/`env_var_count`, `command`, `initial_input`,
`wait_after_command`):

- `ENSO_TAB_ID=<session.id uuid, lowercase>`
- `ENSO_SHIM_DIR=<app support>/shims/bin`
- `ENSO_SESSIONS_DIR=<app support>/agent-sessions`
- `PATH=<shim dir>:<inherited PATH>` (best-effort; real enforcement is the precmd hook)

Gate: only when the "Resume agent sessions" setting is on.

### PATH survival (the real mechanism)

macOS `/etc/zprofile` runs `path_helper` in every login shell, which *demotes* our
prepended dir behind system paths; user dotfiles may clobber PATH entirely. Fix, copied
from cmux and verified: a **one-shot precmd hook** appended to our bundled
`macos/Enso/Resources/ghostty/shell-integration/zsh/ghostty-integration` (libghostty
already injects this file via its ZDOTDIR mechanism — zero dotfile edits):

```zsh
# --- Enso agent-session shims (keep block minimal for upstream merges) ---
if [[ -n "${ENSO_SHIM_DIR:-}" && -d "${ENSO_SHIM_DIR}" ]]; then
    _enso_fix_path() {
        local p="" d
        for d in ${(s.:.)PATH}; do
            [[ "$d" == "$ENSO_SHIM_DIR" ]] && continue
            p="${p:+$p:}$d"
        done
        export PATH="$ENSO_SHIM_DIR:$p"
        builtin hash -r 2>/dev/null
        add-zsh-hook -d precmd _enso_fix_path
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _enso_fix_path
fi
# --- end Enso block ---
```

Runs at first prompt (after zprofile/path_helper/zshrc have all finished), dedup-prepends,
deregisters itself. Same idea appended to `bash/ghostty.bash` (guarded by
`[[ -n "${ENSO_SHIM_DIR:-}" ]]`, using PROMPT_COMMAND once-shot). fish: optional v1 skip.
No shell functions layer in v1 (shim-on-PATH suffices; functions can be added later).

## Wrapper contract (all agents)

Bash, `#!/bin/bash`, no `set -e`/`set -u`; every external var as `${VAR:-}`; every
optional step `|| true`. **Never** write to stdout; errors to stderr only on fatal
resolution failure (exit 127). Must end in `exec "$REAL" ...` (same PID → perfect
signal/exit-code transparency, verified). Safe under pipes (`claude -p | jq`), xargs,
non-interactive shells.

Common prologue:
1. **Passthrough guards** — if `ENSO_TAB_ID` unset, or `ENSO_AGENT_SESSIONS_DISABLED=1`,
   or sessions dir unwritable → resolve real binary and plain `exec`.
2. **Recursion guard** — `ENSO_SHIM_DEPTH` counter, cap 3; beyond cap resolve real and exec.
3. **Real-binary resolution** — rebuild PATH minus own dir and `$ENSO_SHIM_DIR`, then
   `command -v <name>`. Not found → stderr one-liner, exit 127. If a *user's own*
   wrapper script sits earlier in PATH, we correctly exec theirs (their customizations
   apply). Interactive aliases/functions don't exist in our process — not our problem
   at this layer.
4. **Recording** — append single-line JSON to `$ENSO_SESSIONS_DIR/$ENSO_TAB_ID.jsonl`:
   `{"v":1,"event":"...","agent":"claude","sessionId":"...","cwd":"$PWD","ts":<epoch>}`.
   Append is atomic enough at these sizes (single `>>` write of one line).

`enso-hook-relay <agent>`: reads stdin (hook JSON payload), appends
`{"v":1,"event":"hook","agent":"<agent>","payload":<stdin>,"ts":...}` to the tab's map
file (reads `$ENSO_TAB_ID`/`$ENSO_SESSIONS_DIR` from inherited env), prints `{}`,
exits 0. Everything `|| true`. Must be instant — codex blocks synchronously on hooks.

## Claude adapter

Facts (verified on 2.1.208):
- `--session-id <uuid>`: any hex UUID shape (regex `^[0-9a-f]{8}-…$` case-insensitive,
  no version restriction). **Hard-errors "already in use" if
  `projects/<encode(cwd)>/<id>.jsonl` exists** — so mint a FRESH lowercase `uuidgen`
  per launch, never a stable tab-derived ID.
- Transcript path: `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<encode(cwd)>/<id>.jsonl`
  where encode = NFC-normalize then `s/[^a-zA-Z0-9]/-/g` (>200 chars: truncate + base36
  hash suffix).
- `--resume <id>` only finds sessions created in the SAME cwd (project-dir scoped).
- `--settings` accepts inline JSON; hooks from different sources MERGE (all run), so
  injecting ours doesn't disable the user's. But TWO `--settings` flags = replace
  (version-dependent order) — if the user passed their own `--settings`, skip our hook
  injection entirely (degraded: launch-record only; still resumable).
- Hook payloads carry `session_id`, `transcript_path`, `cwd`; SessionStart `source` ∈
  startup|resume|clear|compact; SessionEnd fires even on SIGHUP with `reason:"other"`;
  clean exits give `prompt_input_exit`/`logout`. `/clear` mints a NEW session id —
  hooks are how we track it.
- `cleanupPeriodDays` (default 30) deletes old transcripts — restore must re-check
  transcript existence, never trust the map alone.

Wrapper decision tree (after common prologue):
- Scan argv left-to-right, stop at `--`. First positional that matches a subcommand →
  plain passthrough. Subcommands (2.1.208): `agents auth auto-mode doctor gateway
  install mcp plugin plugins project setup-token ultrareview update upgrade daemon rc
  remote-control config api-key`. Also `-h --help -v --version` anywhere before `--`.
- Value-consuming options must be skipped WITH their value so the value isn't mistaken
  for a subcommand (list: `--settings --model --add-dir --allowedTools --disallowedTools
  --append-system-prompt --output-format --input-format --mcp-config --permission-mode
  --resume --session-id --fallback-model --agents --setting-sources --json-schema
  --betas --file --max-budget-usd --effort --agent --plugin-url -r -c` … be generous;
  unknown `--x` followed by non-dash token: treat conservatively, don't inject if unsure —
  fail open to passthrough).
- User already chose a session — any of `--resume -r --continue -c --session-id
  --fork-session --from-pr` (and `=`-joined forms) → record
  `{"event":"user-session","sessionId":<extracted if parseable>}` and passthrough
  (injecting alongside these ERRORS, it's not just polite).
- Otherwise inject: `SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')`; record
  `{"event":"launch","sessionId":...}`; if user passed `--settings` →
  `exec "$REAL" --session-id "$SESSION_ID" "$@"`, else
  `exec "$REAL" --session-id "$SESSION_ID" --settings "$HOOKS_JSON" "$@"` where
  HOOKS_JSON wires SessionStart + SessionEnd to `"$ENSO_SHIM_DIR/enso-hook-relay claude"`.
- Feature detection: `"$REAL" --help | grep -q -- --session-id`, cached in
  `$ENSO_SESSIONS_DIR/.features-claude-<mtime+size of REAL>`; unsupported → passthrough.

Restore policy: restorable iff latest session's last event is NOT a clean end
(SessionEnd reason ∈ prompt_input_exit|logout|clear) AND transcript file exists and
contains a `"type":"user"` line. Resume command: `claude --resume <id>`.

## Codex adapter

Facts (verified on 0.144.1):
- NO way to choose the ID upfront. Hooks are first-class and stable-by-default:
  inject per-invocation with global flags (valid before subcommands):
  `--enable hooks --dangerously-bypass-hook-trust -c 'hooks.SessionStart=[{hooks=[{type="command",command='''<relay path> codex''',timeout=10000}]}]'`
  (TOML `'''` literal strings; also wire `hooks.Stop`). Nothing written to `~/.codex`.
- **Codex runs hooks synchronously and blocks** — the relay must append + `echo '{}'`
  and exit immediately (cmux hit 35 s hangs here).
- SessionStart payload has `session_id`, `cwd`, `source` (startup|resume|…); fires on
  resume too in current versions.
- Inject ONLY for session entrypoints: bare `codex`, `codex <prompt>`, `codex exec|e`,
  `codex resume`, `codex fork`. Passthrough subcommands: `review login logout mcp
  plugin mcp-server app-server remote-control app completion update doctor sandbox
  debug apply a archive delete unarchive cloud exec-server features help` and
  `-h/--help/-V/--version`.
- Value-consuming globals to skip while scanning: `-c --config -m -p -C --remote -a -s
  --output-last-message --enable --disable`.
- `codex resume <id|name>` / `resume --last` / `exec resume …` → record extracted id
  (`user-session` event), still inject hooks (safe), never add our own selection.
- `codex exec --ephemeral` persists nothing — record nothing.
- Rollouts: `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`; index
  `~/.codex/state_5.sqlite` `threads` (has cwd) — WAL, open read-only.
- Resume from a different cwd triggers an interactive prompt — restore must run from
  the recorded cwd.
- Feature-detect: `"$REAL" --help | grep -q -- --dangerously-bypass-hook-trust` (cached
  as for claude); absent → plain passthrough.
- No SessionEnd event exists → clean-exit can't be observed from hooks. Restore policy
  below compensates.

Restore policy: restorable iff (tab listed in the quit snapshot with agent=codex) OR
(no snapshot exists — crash — and last event < 12 h old); AND a rollout file matching
the uuid exists under `~/.codex/sessions/` (bounded glob). Resume command:
`codex resume <id>`.

## Quit snapshot

In `QuitGuard.consentsToTerminate()`, after the user confirms: write
`<app support>/agent-sessions/.quit-snapshot.json` —
`{"ts":..., "tabs":{"<tab-uuid>":"claude"|"codex"|...}}` from each live session's
`runningProcess` (the existing foreground-process detection). Consumed (deleted) after
being read at next launch. Crash → file absent/stale (ts check) → per-agent fallback
policies above.

## Restore flow (Swift)

`AgentSessionStore` (new, small):
- `init`: scan `agent-sessions/*.jsonl`; delete files whose tab-id has no session in
  `TerminalSessionStore` (orphan GC); compact each remaining file in memory to
  `AgentSessionRecord {agent, sessionID, cwd, lastEvent, lastEventDate}` (latest launch/
  hook/user-session wins; hook payload sessionId overrides launch sessionId — `/clear`).
- `restorableRecord(for tabID:) -> AgentSessionRecord?` applying per-adapter policy +
  quit snapshot + setting gate. Consumed once per tab per app run.

`GhosttySurfaceManager.view(for:)`: if a restorable record exists and the setting is on,
build the surface with `initial_input` = resume command + `"\n"`. If the record's cwd ≠
session.workingDirectory, prefix `cd '<recorded cwd>' && `. Escape single quotes.
`initial_input` types into the PTY at spawn — visible and honest in the terminal. If
first-prompt timing garbles it in practice (powerlevel10k instant prompt etc.), the
fallback is a cmux-style one-shot self-deleting launcher script via `config.command` —
keep the call site isolated so the mechanism can be swapped in one place.

Adapter protocol:

```swift
protocol AgentSessionAdapter {
    var agentID: String { get }          // "claude", "codex" — matches wrapper names
    var wrapperResourceName: String { get }
    // nil = no restore; otherwise the full command (resume OR fresh relaunch),
    // every token shell-quoted, env prefix included. Decision logic (transcript
    // checks, snapshot gating) lives inside each adapter.
    func restoreCommand(for record: AgentSessionRecord, quitSnapshot: QuitSnapshot?, now: Date) -> String?
}
```

Registry array in one place; adding an agent = one Swift file + one policy + one
wrapper script.

## Fresh-relaunch mode

A tab whose agent was RUNNING at quit (its tab is listed in the quit snapshot) but
whose conversation is not resumable — claude: transcript pruned or no `"type":"user"`
line yet; codex: session id never learned or rollout gone — relaunches the agent
FRESH with its sanitized launch arguments: `claude <preserved…>` / `codex <preserved…>`.
This restores the tab's *shape*, not just conversations. Two hard gates:

- Fresh-relaunch requires a quit-snapshot entry for the tab. The codex 12-hour crash
  fallback applies only to resumes; a crash never spuriously relaunches agents.
- Sanitizer rejection (below) suppresses restore entirely, including fresh-relaunch.

## Launch-context recording + sanitized argv replay

Wrappers record two extra fields on `launch` and `user-session` events (fail-open —
an encoding failure records the event without them):

- `argvB64` — base64 of the ORIGINAL user argv (pre-injection), NUL-delimited
  (`printf '%s\0' "$@" | base64 | tr -d '\n'`; empty argv → empty string).
- `configDir` — `${CLAUDE_CONFIG_DIR:-}` / `${CODEX_HOME:-}`, omitted when empty.
  Carried back into the restore command as an env prefix
  (`CLAUDE_CONFIG_DIR='…' claude --resume <id> …`) AND used for the adapter's
  transcript/rollout existence checks, so sessions under a custom config root restore.

`AgentLaunchSanitizer` (ported from cmux's policy-driven sanitizer, trimmed to our
agents) filters the recorded argv into three tiers before replay:

- **preserved** — allowlisted session-shaping options with their values (model,
  permission mode, MCP config, add-dir, …; variadic and `=`-joined forms handled).
- **dropped** — session-selection and one-shot options the restore command
  re-supplies itself (claude: `--resume -r --continue -c --session-id --fork-session
  --from-pr --file --worktree -w`; codex: `--last --all --image -i --remote
  --remote-auth-token-env`). Dropping these is what makes a restore-of-a-restore
  idempotent: the argv recorded from our own typed `claude --resume <id> <preserved>`
  sanitizes back to the same preserved set.
- **rejected** — the launch was never an interactive session; the ENTIRE restore is
  abandoned (claude: `-p --print --no-session-persistence`; both agents: any known
  non-session subcommand, incl. codex `exec`/`fork`).

Positional prompts are stripped in both modes (scanning stops at the first
non-option token; `codex resume <id>`'s own id is stripped, not treated as prompt).
Every replayed token goes through cmux's `shellQuoted` (safe-charset passthrough,
otherwise single-quote wrap with `'\''` escaping); session ids are additionally
regex-validated. Codex resumes append `-c check_for_update_on_startup=false` unless
the preserved args already set it (any `-c`/`--config`, split or `=`-joined form) so
the restored TUI doesn't land on the blocking update picker.

Deliberately no HMAC/signing of the map files: the replay surface is a fixed command
template plus an allowlisted, shell-quoted argv from a user-writable-anyway local
file — quoting and the allowlist bound what it can express, matching cmux's own
posture for agent-session restore.

## Settings

One toggle in SettingsPanelView: "Resume agent sessions on relaunch"
(`UserDefaults` key `agentSessionRestoreEnabled`, default **true**). Off → no env
injection on new surfaces, no restore at launch. Recording costs nothing and follows
the same gate (env vars absent → wrappers pass through inertly even if still on PATH).

## Live attention events (#30)

The map files carry more than restore state. The claude wrapper also registers
`Notification` (claude is waiting on a permission prompt or input; payload has a
human-readable `message`) and `Stop` (claude finished responding) hooks through the
same relay, and the codex wrapper's existing `hooks.Stop` serves the same role.
`AgentAttentionWatcher` tails the map files while the app runs — a 1s stat-and-offset
poll that reads only appended bytes — and surfaces these events for tabs the user
isn't looking at as the sidebar's attention dot plus a clickable system notification
(`AgentNotificationCenter`); selecting the tab clears the dot. Restore compaction is
untouched: unknown hook names only refresh session id/cwd/timestamps, so recording
and restore semantics are unchanged, and the extra few lines per turn keep map files
well within the small-file envelope.

## Cleanup

- App launch: rewrite shims dir (version stamp), orphan-GC map files, delete stale
  quit snapshot after reading.
- Tab close (`TerminalSessionStore.close`): delete the tab's map file.
- Map files are small (a few lines); no size management needed beyond tab-close GC.

## Failure envelope (invariants)

- Any wrapper failure → user's command runs exactly as if Enso didn't exist.
- Any restore failure → tab opens a plain shell at its cwd (today's behavior).
- `claude --resume` against a pruned transcript → visible one-line error, shell intact.
- Wrappers never touch stdout, never prompt, never block on the app.
