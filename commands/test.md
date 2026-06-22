# Compaction Advisor Diagnostic Test

Run these diagnostic checks and report results:

## 1. Plugin Installation
Run: `ls ~/.claude/plugins/cache/compaction-advisor/compaction-advisor/`

## 2. Scripts Present
Run: `ls -la ~/.claude/plugins/cache/compaction-advisor/compaction-advisor/*/scripts/`

All four should be present: `context_status.sh`, `inject_context.sh`, `checkpoint_advisor.sh`, `precompact_advisor.sh`.

## 3. Session State Files
Run: `ls -la ~/.claude/context_state_*.json`

If no files found, the status line hasn't written state yet.

## 4. Status Line Config
Run: `jq '.statusLine' ~/.claude/settings.json`

## 5. Plugin Hook Config
Run: `cat ~/.claude/plugins/cache/compaction-advisor/compaction-advisor/*/hooks/hooks.json`

Should configure three hooks: `UserPromptSubmit`, `PostToolUse`, `PreCompact`.

Note: For plugin installs, hooks load from the plugin's hooks.json (not user's settings.json).

## 6. State File Content & Counters
Run: `jq '.' ~/.claude/context_state_*.json | tail -20`

Confirm these tracking fields exist (added in v2.1.0): `tool_count`, `last_checkpoint`,
`read_count`, `last_subagent_hint`. They drive checkpoint and subagent-delegation hints,
and are reset to 0 by the PreCompact hook after each compaction.

## 7. Active Configuration (optional overrides)
Run: `env | grep CONTEXT_ADVISOR_ || echo "(using defaults)"`

Defaults if unset: buffer 23%, thresholds critical <15k / warning <30k / caution <50k free.
Override via `CONTEXT_ADVISOR_BUFFER_PERCENT`, `CONTEXT_ADVISOR_CRITICAL_K`,
`CONTEXT_ADVISOR_WARNING_K`, `CONTEXT_ADVISOR_CAUTION_K`.

## Summary
Report what's working. Notes:
- If status is "safe", the hooks correctly output nothing (0 tokens).
- The subagent-delegation hint fires only when context is concerning AND a burst of
  read-only operations (Read/Grep/Glob or read-only Bash like grep/find/cat) has piled up.
