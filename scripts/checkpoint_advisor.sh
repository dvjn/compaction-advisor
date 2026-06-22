#!/bin/bash
# Checkpoint Advisor - PostToolUse Hook
#
# Monitors tool usage during long tasks and nudges Claude in two ways
# when context is getting low:
#
# 1. Checkpoint: after 8+ modifying operations (Edit/Write/NotebookEdit and
#    writing Bash commands), suggest pausing to /compact before mid-task
#    compaction hits.
# 2. Subagent delegation: after a burst of read-only exploration (Read/Grep/
#    Glob and read-only Bash like grep/find/cat), suggest offloading further
#    exploration to a subagent (Task tool) so bulky output never enters this
#    context.
#
# Both only fire when context is actually concerning (not safe), so the
# token cost stays at zero while there's healthy headroom.

set -euo pipefail

# Read hook input to get session ID
input=$(cat)
SESSION_ID=$(echo "$input" | jq -r '.session_id // "default"' | tr -d '[:space:]' | cut -c1-16)
TOOL_NAME=$(echo "$input" | jq -r '.tool_name // "unknown"')
STATE_FILE="$HOME/.claude/context_state_${SESSION_ID}.json"

# Check if state file exists (status line hasn't run yet → nothing to do)
if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi

# Skip if the state is stale (status line hasn't refreshed recently). Without
# this, a checkpoint/subagent hint could fire off an out-of-date status.
# GNU (Linux) first, then BSD/macOS — same ordering as inject_context.sh.
FILE_TIME=$(stat -c %Y "$STATE_FILE" 2>/dev/null || stat -f %m "$STATE_FILE" 2>/dev/null || echo 0)
CURRENT_TIME=$(date +%s)
if [ $((CURRENT_TIME - FILE_TIME)) -gt 120 ]; then
    exit 0
fi

# Read current state
STATUS=$(jq -r '.status // "safe"' "$STATE_FILE")
FREE_K=$(jq -r '.free_k // 0' "$STATE_FILE")
TOOL_COUNT=$(jq -r '.tool_count // 0' "$STATE_FILE")
LAST_CHECKPOINT=$(jq -r '.last_checkpoint // 0' "$STATE_FILE")
READ_COUNT=$(jq -r '.read_count // 0' "$STATE_FILE")
LAST_SUBAGENT_HINT=$(jq -r '.last_subagent_hint // 0' "$STATE_FILE")

# Classify the tool into a tracking class: read | modify | skip
#   read   - read-only exploration → feeds the subagent-delegation hint
#   modify - significant operation  → feeds the checkpoint counter
#   skip   - don't track
classify_tool() {
    case "$TOOL_NAME" in
        Read|Grep|Glob)      echo "read";   return ;;
        Edit|Write|NotebookEdit) echo "modify"; return ;;
        Task)                echo "skip";   return ;;  # already delegating
        Bash)                ;;                          # inspect command below
        *)                   echo "skip";   return ;;
    esac

    # Bash: read-only commands count as exploration; anything else as a
    # modifying op. Be conservative — if we can't be sure it's read-only,
    # treat it as modifying.
    local cmd first sub
    cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

    # Output redirects, tee, or command chaining can hide a write → modify.
    case "$cmd" in
        *">"*|*"|tee"*|*" tee "*|*"&&"*|*";"*) echo "modify"; return ;;
    esac

    first=$(echo "$cmd" | awk '{print $1}')
    first=${first##*/}   # strip any leading path (/usr/bin/grep → grep)

    case "$first" in
        cat|ls|grep|rg|egrep|fgrep|find|fd|head|tail|wc|tree|stat|file|pwd|\
        echo|printf|which|type|env|date|du|df|ps|sort|uniq|cut|column|less|\
        more|diff|comm|jq|yq|whoami|id|hostname|uname|dirname|basename|\
        realpath|readlink|tac|nl|od|xxd|hexdump)
            echo "read"; return ;;
        git)
            # Only clearly read-only git subcommands count as exploration.
            sub=$(echo "$cmd" | awk '{print $2}')
            case "$sub" in
                status|log|diff|show|blame|ls-files|rev-parse|describe|\
                shortlog|reflog|cat-file|grep|whatchanged)
                    echo "read"; return ;;
            esac
            echo "modify"; return ;;
    esac

    echo "modify"
}

CLASS=$(classify_tool)

case "$CLASS" in
    skip)
        exit 0
        ;;

    read)
        # Read-only exploration. Track it: a long burst of these while
        # context is tight is the prime signal to delegate to a subagent.
        NEW_READ_COUNT=$((READ_COUNT + 1))
        READS_SINCE_HINT=$((NEW_READ_COUNT - LAST_SUBAGENT_HINT))

        jq --argjson rc "$NEW_READ_COUNT" '.read_count = $rc' "$STATE_FILE" > "$STATE_FILE.tmp"
        mv "$STATE_FILE.tmp" "$STATE_FILE"

        # Suggest delegation once context is concerning and enough reads
        # have piled up since the last hint.
        MIN_READS_FOR_HINT=6
        if [ "$STATUS" != "safe" ] && [ $READS_SINCE_HINT -ge $MIN_READS_FOR_HINT ]; then
            jq --argjson lh "$NEW_READ_COUNT" '.last_subagent_hint = $lh' "$STATE_FILE" > "$STATE_FILE.tmp"
            mv "$STATE_FILE.tmp" "$STATE_FILE"

            echo "<context-subagent-hint>"
            echo "DELEGATE TO SUBAGENT: ${READS_SINCE_HINT} read-only operations and only ${FREE_K}k free."
            echo "If you're still exploring/searching, spawn a subagent (Task tool) for it — the"
            echo "bulky file and search output stays in the subagent's context and only its summary"
            echo "returns here, keeping this context lean."
            echo "</context-subagent-hint>"
        fi
        exit 0
        ;;
esac

# CLASS == modify: fall through to checkpoint logic.

# Increment tool count for modifying operations
NEW_TOOL_COUNT=$((TOOL_COUNT + 1))
TOOLS_SINCE_CHECKPOINT=$((NEW_TOOL_COUNT - LAST_CHECKPOINT))

# Update state file with new tool count
jq --argjson tc "$NEW_TOOL_COUNT" '.tool_count = $tc' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"

# Checkpoint threshold: don't warn until 8+ operations since the last checkpoint
MIN_TOOLS_FOR_CHECKPOINT=8

# Only suggest checkpoint if:
# 1. Context is concerning (not safe)
# 2. Enough operations since last checkpoint
if [ "$STATUS" != "safe" ] && [ $TOOLS_SINCE_CHECKPOINT -ge $MIN_TOOLS_FOR_CHECKPOINT ]; then

    # Update last checkpoint marker
    jq --argjson lc "$NEW_TOOL_COUNT" '.last_checkpoint = $lc' "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"

    # Output checkpoint suggestion (goes to Claude's context)
    case "$STATUS" in
        critical)
            echo "<context-checkpoint>"
            echo "CHECKPOINT RECOMMENDED: Context critically low (${FREE_K}k free) after ${TOOLS_SINCE_CHECKPOINT} operations."
            echo "Good time to pause and /compact. Summarize progress so far and key context to preserve."
            echo "If the remaining edits are repetitive/mechanical (same change across many files,"
            echo "scaffolding), delegate that batch to a subagent (Task tool) so the diffs and output"
            echo "stay out of this context."
            echo "</context-checkpoint>"
            ;;
        warning)
            echo "<context-checkpoint>"
            echo "CHECKPOINT SUGGESTED: Context at ${FREE_K}k free after ${TOOLS_SINCE_CHECKPOINT} operations."
            echo "If more significant work remains, consider /compact now to avoid mid-task interruption,"
            echo "or hand a batch of repetitive edits to a subagent (Task tool) to keep this context lean."
            echo "</context-checkpoint>"
            ;;
        caution)
            # Only warn on caution if many operations
            if [ $TOOLS_SINCE_CHECKPOINT -ge 15 ]; then
                echo "<context-checkpoint>"
                echo "Context update: ${FREE_K}k free after ${TOOLS_SINCE_CHECKPOINT} operations. Still OK for medium tasks."
                echo "</context-checkpoint>"
            fi
            ;;
    esac
fi
