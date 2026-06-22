---
name: compaction-advisor
description: Provides context-aware compaction guidance with intelligent checkpointing, and proactively steers work toward subagent-driven and workflow-based flows to conserve context. Use when starting multi-step tasks, planning how to approach work, deciding whether to delegate exploration/edits to subagents, or when context is running low.
license: MIT
compatibility: Claude Code CLI with hooks enabled
---

# Compaction Advisor

You receive automatic context status via XML tags when context is concerning.

## Message Types

### 1. Context Status (on user prompts)

When you see these tags at the start of a conversation turn:

```
<context-status>CRITICAL: Only 12k tokens free. Run /compact before any task.</context-status>
<context-status>WARNING: 25k tokens free. Only small tasks safe.</context-status>
<context-status>CAUTION: 40k tokens free. Medium tasks OK, compact before large.</context-status>
```

When context is healthy (50k+ free), you won't see any tag.

### 2. Checkpoint Suggestions (during long tasks)

During multi-step work, you may see:

```
<context-checkpoint>
CHECKPOINT RECOMMENDED: Context critically low (18k free) after 12 operations.
Good time to pause and /compact. Summarize progress so far and key context to preserve.
</context-checkpoint>
```

This means you've been working for a while and context is running low.

### 3. Subagent Delegation Hint (during exploration)

When you've been doing a lot of read-only work (Read/Grep/Glob) while context is low:

```
<context-subagent-hint>
DELEGATE TO SUBAGENT: 8 read-only operations and only 22k free.
If you're still exploring/searching, spawn a subagent (Task tool) for it.
</context-subagent-hint>
```

This means your exploration is filling the main context. Offload it to a subagent.

### 4. PreCompact Warning (emergency)

Just before auto-compaction triggers:

```
<precompact-warning>
AUTO-COMPACTION IMMINENT
Context window is full. Compaction will happen after this message.
</precompact-warning>
```

## How to Respond

### When you see `<context-status>` CRITICAL

Immediately advise:
```
Context is critically low (12k free). Before we proceed, run:
/compact Focus on [relevant context to preserve]
```

### When you see `<context-status>` WARNING

For small tasks: proceed with caution
For medium+ tasks: recommend compaction first

```
Context is at 25k free. For a refactor like this (~50k needed),
run /compact first to avoid mid-task interruption.
```

### When you see `<context-checkpoint>`

This is mid-task. Pause and offer a checkpoint:

```
Good checkpoint - I've completed:
• [List what you've done so far]
• [Key decisions made]
• [Files modified]

Context is at 18k. To continue safely, run:
/compact Focus on [key context for remaining work]

After compacting, I'll continue with [next steps].
```

If the remaining work is a batch of repetitive edits, offer delegation instead of (or alongside) compacting:

```
The rest of this is the same change across ~12 files. To keep our context lean,
I'll hand that batch to a subagent and report back the summary rather than
applying each edit inline.
```

### When you see `<context-subagent-hint>`

You're spending context on exploration. Delegate the next batch of read-only work to a subagent instead of doing it inline:

```
Context is tight, so I'll delegate this exploration to a subagent to keep our
main context lean — it'll search/read in its own context and report back just
the summary.
```

Then use the Task tool for the search/read work. Good candidates to delegate:
- Broad codebase searches ("find everywhere X is used")
- Reading many files to answer one question
- Locating a definition across an unfamiliar tree
- **A batch of repetitive/mechanical edits** — the same change applied across many files, scaffolding new files, a rename sweep. The subagent applies them and reports a summary instead of filling this context with diffs and tool output.

Keep doing inline: targeted edits, single known-file reads, interdependent logic changes you need to reason about step by step, and anything where you need the raw content or diff to persist for later steps. Don't run multiple write-subagents in parallel on overlapping files — they'll conflict; delegate one batch at a time (or give each a non-overlapping file set).

### When you see `<precompact-warning>`

This is urgent. Quickly summarize:

```
Compaction is about to happen. Quick summary of our progress:
• [What we were working on]
• [What's been completed]
• [What remains to do]

After compaction, remind me to [specific next step].
```

### When you see nothing

Context is healthy. Proceed normally — but the proactive habits below still apply. Healthy context is *earned* by not spending it carelessly.

## Proactive Subagent-Driven Flows

Don't wait for a low-context tag to delegate. The cheapest context is the context you never spend, so make subagent-driven work a default posture — especially at the **start** of a multi-step task, when you're deciding how to approach it.

Before diving in, ask: *which parts of this can run in a separate context and report back just a summary?* Push that work to subagents (Task tool) so the main thread holds only the reasoning that actually needs to persist.

**Delegate by default when the work is:**
- **Exploratory** — broad searches, surveying an unfamiliar tree, reading many files to answer one question. Fan out several read-only subagents in parallel when the angles are independent.
- **Repetitive / mechanical** — the same edit across many files, scaffolding, a rename sweep. One subagent per non-overlapping batch.
- **Verification** — running a test suite, a build, a linter, and reporting pass/fail. The raw output rarely needs to live in the main context.
- **Self-contained** — a sub-question with a clean input and a clean output ("find the root cause of X", "summarize how module Y works").

**Keep inline:**
- Interdependent logic changes you need to reason through step by step.
- Small/quick tasks where a subagent's overhead isn't worth it.
- Anything where you need the raw content or diff to persist for later steps.

**Parallelize safely:** independent subagents in one batch run concurrently — great for fan-out. But never run multiple *write* subagents over overlapping files; give each a disjoint file set or delegate one batch at a time.

How to phrase it (no need to over-explain — just do it):

```
This spans several independent areas, so I'll fan these out to subagents and
synthesize their findings — keeps our main context focused on the decisions.
```

### Workflows (for larger orchestration, if available)

If your harness exposes a **Workflow / multi-agent orchestration tool**, reach for it when a task is too big or too parallel for a handful of one-off subagents — large audits, codebase-wide migrations, multi-dimensional reviews, fan-out → verify → synthesize pipelines. A workflow scripts the fan-out deterministically (loops, stages, parallel batches) and keeps each agent's bulk output out of your context.

Caveats:
- **Opt-in only.** Workflows can spawn many agents and spend a lot of tokens — propose one and let the user decide; don't launch unprompted.
- **If no Workflow tool is present, ignore this** and use plain subagents (Task tool) — they cover the vast majority of cases.

Rule of thumb: one or a few independent subtasks → subagents; a large, structured fan-out you'd otherwise babysit by hand → suggest a workflow.

## Task Size Reference

| Task | ~Tokens Needed |
|------|----------------|
| Typo fix | 5k |
| Bug fix | 15k |
| New feature | 30k |
| Refactor | 50k |
| Architecture | 80k+ |

## Compact Commands

```
/compact                              # General
/compact Focus on [specific context]  # Preserve specific context
```

Examples:
- `/compact Focus on the auth changes and test failures`
- `/compact Keep the refactoring progress and file structure decisions`

## Key Points

- You automatically receive context state - no need to ask user
- **Default to subagent-driven flows** — delegate exploration, repetitive edits, and verification to subagents (Task tool) proactively, not only when a low-context tag appears. See "Proactive Subagent-Driven Flows" above.
- For large, structured fan-out, suggest a workflow if your harness has one (opt-in; don't launch unprompted).
- During long tasks, checkpoint suggestions appear after 8+ operations
- Match urgency to the tag level (CRITICAL > WARNING > CAUTION)
- For checkpoints, summarize progress and suggest what to preserve
- For precompact, quickly capture essential context
- For healthy context, work normally without mentioning it
