#!/bin/bash
# Enso claude wrapper — installed as `claude` in Enso's shim dir.
#
# Inside an Enso terminal (ENSO_TAB_ID set) session launches get a freshly
# minted --session-id (claude hard-errors on a reused id, so never a stable
# one) plus SessionStart/SessionEnd hooks that report the live session id to
# the tab's map file in ENSO_SESSIONS_DIR. That map is what lets the app
# resume the conversation after a relaunch. Outside Enso, or on any internal
# failure, the real claude runs exactly as if this wrapper didn't exist.
#
# Contract: no `set -e`/`set -u` (an aborting wrapper breaks the user's
# claude), never write to stdout, always end in exec, and exit 127 with a
# single stderr line only when no real binary exists.

enso_self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

# Resolve the real claude by walking PATH minus our own shim dir; a user's
# own earlier-in-PATH claude wrapper is honored (their customizations apply).
enso_find_real() {
    local d candidate
    local IFS=:
    for d in ${PATH:-}; do
        [[ -n "$d" && "$d" != "$enso_self_dir" ]] || continue
        [[ -n "${ENSO_SHIM_DIR:-}" && "$d" == "${ENSO_SHIM_DIR%/}" ]] && continue
        candidate="$d/claude"
        [[ -e "$candidate" && "$candidate" -ef "$0" ]] && continue
        if [[ -f "$candidate" && -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

REAL="$(enso_find_real)" || { echo "enso: claude not found in PATH" >&2; exit 127; }

# Recursion guard: a shim chain that bounces back here stops injecting.
enso_depth="${ENSO_SHIM_DEPTH:-0}"
case "$enso_depth" in ''|*[!0-9]*) enso_depth=0 ;; esac
if [[ "$enso_depth" -ge 3 ]]; then
    exec "$REAL" "$@"
fi
export ENSO_SHIM_DEPTH="$((enso_depth + 1))"

# Passthrough guards: not an Enso tab, opted out, or nowhere to record.
if [[ -z "${ENSO_TAB_ID:-}" || -z "${ENSO_SESSIONS_DIR:-}" || "${ENSO_AGENT_SESSIONS_DISABLED:-}" == "1" ]]; then
    exec "$REAL" "$@"
fi
if [[ ! -d "${ENSO_SESSIONS_DIR}" || ! -w "${ENSO_SESSIONS_DIR}" ]]; then
    exec "$REAL" "$@"
fi
# A claude spawned from INSIDE a running agent (its Bash tool inherits this
# environment) must not overwrite the tab's session record with its own.
# ENSO_AGENT_ACTIVE marks sessions this wrapper started; CLAUDECODE marks
# ones started around it (e.g. via an absolute path).
if [[ -n "${ENSO_AGENT_ACTIVE:-}" || -n "${CLAUDECODE:-}" ]]; then
    exec "$REAL" "$@"
fi

enso_json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# Appends one map event; failures are silently ignored (fail open).
# $3.. is the ORIGINAL user argv (pre-injection), recorded NUL-delimited in
# base64 so the app can replay the launch shape on restore; configDir
# remembers a custom CLAUDE_CONFIG_DIR so restore resumes against the right
# transcript root. Both are best-effort — an encoding failure records the
# event without them and never blocks the exec.
enso_record() {
    local event="$1" session_id="${2-}"
    shift 2 || true
    local argv_b64=""
    if [[ $# -gt 0 ]]; then
        argv_b64="$( { printf '%s\0' "$@" | base64 | tr -d '\n'; } 2>/dev/null || true)"
    fi
    local config_dir_field=""
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
        config_dir_field=",\"configDir\":\"$(enso_json_escape "$CLAUDE_CONFIG_DIR")\""
    fi
    printf '{"v":1,"event":"%s","agent":"claude","sessionId":"%s","cwd":"%s","argvB64":"%s"%s,"ts":%s}\n' \
        "$event" \
        "$(enso_json_escape "$session_id")" \
        "$(enso_json_escape "$PWD")" \
        "$argv_b64" \
        "$config_dir_field" \
        "$(date +%s 2>/dev/null || printf '0')" \
        >> "${ENSO_SESSIONS_DIR}/${ENSO_TAB_ID}.jsonl" 2>/dev/null || true
}

# Options whose next token is a value, so the scanner never mistakes that
# value for a subcommand or prompt (generous by design; unknown options get
# the conservative treatment in the scanner instead).
enso_option_consumes_value() {
    case "$1" in
        --settings|--model|--add-dir|--allowedTools|--allowed-tools|\
        --disallowedTools|--disallowed-tools|--append-system-prompt|\
        --output-format|--input-format|--mcp-config|--permission-mode|\
        --fallback-model|--agents|--agent|--setting-sources|--json-schema|\
        --betas|--file|--max-budget-usd|--effort|--plugin-url|--plugin-dir|\
        --system-prompt|--tools|--debug-file|--name|-m|-n)
            return 0 ;;
    esac
    return 1
}

# Boolean flags we know take no value (keeps the conservative unknown-option
# rule from turning common invocations into passthrough).
enso_is_known_flag() {
    case "$1" in
        -p|--print|-d|--debug|--verbose|--dangerously-skip-permissions|\
        --mcp-debug|--strict-mcp-config|--include-partial-messages|\
        --replay-user-messages|--ide|--no-ide)
            return 0 ;;
    esac
    return 1
}

# The user already chose a session. Injecting --session-id alongside any of
# these is a hard error in claude 2.1.x, not just impolite.
enso_is_session_choice_flag() {
    case "$1" in
        --resume|--resume=*|-r|--continue|-c|--session-id|--session-id=*|\
        --fork-session|--fork-session=*|--from-pr|--from-pr=*)
            return 0 ;;
    esac
    return 1
}

# claude 2.1.208 subcommands; none of them starts a conversation.
enso_is_subcommand() {
    case "$1" in
        agents|auth|auto-mode|doctor|gateway|install|mcp|plugin|plugins|\
        project|setup-token|ultrareview|update|upgrade|daemon|rc|\
        remote-control|config|api-key)
            return 0 ;;
    esac
    return 1
}

enso_mode=inject
enso_user_settings=false
enso_user_session_id=""

# Left-to-right argv scan, stopping at `--`. Decides between injecting a
# session id, recording the user's own session choice, or passing through.
enso_scan_args() {
    local -a args=("$@")
    local i=0 arg next seen_positional=false
    while [[ $i -lt ${#args[@]} ]]; do
        arg="${args[$i]}"
        case "$arg" in
            --)
                return 0
                ;;
            -h|--help|-v|--version)
                enso_mode=passthrough
                return 0
                ;;
        esac
        if enso_is_session_choice_flag "$arg"; then
            enso_mode=user-session
            case "$arg" in
                --resume=*) enso_user_session_id="${arg#--resume=}" ;;
                --session-id=*) enso_user_session_id="${arg#--session-id=}" ;;
                --resume|-r|--session-id)
                    next="${args[$((i + 1))]:-}"
                    [[ -n "$next" && "$next" != -* ]] && enso_user_session_id="$next"
                    ;;
            esac
            return 0
        fi
        case "$arg" in
            --settings)
                enso_user_settings=true
                i=$((i + 2))
                continue
                ;;
            --settings=*)
                enso_user_settings=true
                ;;
            -*)
                if [[ "$arg" != *=* ]] && enso_option_consumes_value "$arg"; then
                    i=$((i + 2))
                    continue
                fi
                # Unknown option followed by a bare token: that token may be
                # a value we'd misread as prompt or subcommand — fail open.
                if [[ "$seen_positional" == false && "$arg" != *=* ]] && ! enso_is_known_flag "$arg"; then
                    next="${args[$((i + 1))]:-}"
                    if [[ -n "$next" && "$next" != -* ]]; then
                        enso_mode=passthrough
                        return 0
                    fi
                fi
                ;;
            *)
                # First bare token: a known subcommand passes through, any
                # other token is the prompt of an interactive session. Keep
                # scanning either way so a later session flag is still seen.
                if [[ "$seen_positional" == false ]]; then
                    seen_positional=true
                    if enso_is_subcommand "$arg"; then
                        enso_mode=passthrough
                        return 0
                    fi
                fi
                ;;
        esac
        i=$((i + 1))
    done
    return 0
}

# `--session-id` support probe, cached per binary (path + mtime + size) so
# the ~1s `claude --help` runs once per installed version.
enso_supports_session_id() {
    local stamp cache verdict
    stamp="$(stat -f '%m-%z' "$REAL" 2>/dev/null || true)"
    if [[ -n "$stamp" ]]; then
        cache="${ENSO_SESSIONS_DIR}/.features-claude-$(printf '%s' "$REAL" | cksum 2>/dev/null | tr -c '0-9\n' '-' | tr -d '\n')-${stamp}"
        case "$(cat "$cache" 2>/dev/null)" in
            yes) return 0 ;;
            no) return 1 ;;
        esac
    fi
    verdict=no
    if "$REAL" --help 2>/dev/null | grep -q -- '--session-id'; then
        verdict=yes
    fi
    if [[ -n "$stamp" && -n "${cache:-}" ]]; then
        printf '%s' "$verdict" >| "$cache" 2>/dev/null || true
    fi
    [[ "$verdict" == "yes" ]]
}

enso_scan_args "$@"

if [[ "$enso_mode" == "passthrough" ]]; then
    exec "$REAL" "$@"
fi

# Everything below starts (or resumes) a session; mark the process tree so
# nested claude runs inside it stay out of the tab's map.
export ENSO_AGENT_ACTIVE=1

if [[ "$enso_mode" == "user-session" ]]; then
    enso_record user-session "$enso_user_session_id" "$@"
    exec "$REAL" "$@"
fi

if ! enso_supports_session_id; then
    exec "$REAL" "$@"
fi

ENSO_SESSION_ID="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')" || ENSO_SESSION_ID=""
if [[ -z "$ENSO_SESSION_ID" ]]; then
    exec "$REAL" "$@"
fi

enso_record launch "$ENSO_SESSION_ID" "$@"

enso_relay="${ENSO_SHIM_DIR:-$enso_self_dir}/enso-hook-relay"
if [[ "$enso_user_settings" == true || ! -x "$enso_relay" ]]; then
    # Two --settings flags REPLACE each other (which one wins is version
    # dependent), so the user's own --settings must travel alone. Degraded
    # mode: launch record only, still resumable.
    exec "$REAL" --session-id "$ENSO_SESSION_ID" "$@"
fi

# claude merges hooks from different settings sources, so injecting ours
# never disables the user's own hooks. SessionStart/SessionEnd feed restore;
# Notification (claude is waiting on a permission prompt or input) and Stop
# (claude finished responding) feed the app's live attention watcher.
enso_relay_json="$(enso_json_escape "$enso_relay")"
enso_hook_entry='[{"matcher":"","hooks":[{"type":"command","command":"\"'"$enso_relay_json"'\" claude","timeout":10}]}]'
ENSO_HOOKS_JSON='{"hooks":{"SessionStart":'"$enso_hook_entry"',"SessionEnd":'"$enso_hook_entry"',"Notification":'"$enso_hook_entry"',"Stop":'"$enso_hook_entry"'}}'

exec "$REAL" --session-id "$ENSO_SESSION_ID" --settings "$ENSO_HOOKS_JSON" "$@"
