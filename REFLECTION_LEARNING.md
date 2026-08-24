# Companion Reflection Learning

Companion Bot now reads its own prior observations from PARA to build context across reflection cycles. This prevents the "tired bot" problem — instead of making fresh observations every 6 hours, Companion now notices what it's been thinking about and evolves its thinking.

## How It Works

### 1. Write Path (Existing)
Every 6 hours, Companion writes a reflection to:
```
areas/companion/observations/{date}-angle-{angle}.md
```

Example: `areas/companion/observations/2026-08-24-angle-3.md`

### 2. Read Path (New)
When generating the next reflection, Companion:

**ParaClient module:**
- `read_file/2` — Fetch a specific reflection file
- `list_directory/3` — List all reflections for an angle
- `search/2` — Search across reflections

**ReflectionHistory module:**
- `summarize_prior_reflections/2` — Fetch last N reflections for an angle
- Returns: count, date range, themes, blockers, formatted context text

### 3. Prompt Enhancement (New)
In `HeartbeatHandler.generate_reflection/1`:
- Fetch prior reflection summary for the current angle
- Enhance the LLM prompt with context: *"You've been thinking about this for 3 cycles (Aug 22–24). Patterns noticed: X, Y. Blockers: Z."*
- This gives the LLM context to notice loops and evolve thinking

### 4. Graceful Degradation
If PARA is unavailable (network issue, service down), Companion:
- Logs a warning but does NOT fail
- Falls back to the original reflection query
- Continues normally

## Design Principles

**No artificial fatigue:** Companion's enhanced context isn't designed to make it "tired" of thinking about the same thing. Instead, it's designed to help it *understand* the loop so it can ask better questions.

**One card, not a dashboard:** The context injected into the prompt is brief and actionable, not a data dump. It tells the LLM: "You've been returning to this theme — what's changed? What's blocking it?"

**The learning happens in the LLM prompt, not in Companion code.** Companion just provides the context. The LLM decides how to use it — to deepen the reflection, notice patterns, or suggest concrete next steps.

## Example Reflection Evolution

**Cycle 1 (Aug 22, angle 3):**
> You've been thinking about restoring your third pillar (running/martial arts). What would rebuilding rhythm look like?

*Reflection:* "Running is tied to identity, but the Greece trip is eating August. September could be a restart."

**Cycle 2 (Aug 23, angle 3):**
> You've been thinking about this for 2 cycles. What's changed? Is the Greece trip the real blocker, or is it permission?

*Reflection:* "Greece IS the anchor. After Sep 11, I can rebuild running as a grounding practice, not a performance."

**Cycle 3 (Aug 24, angle 3):**
> You've been thinking about this for 3 cycles (Aug 22–24). Patterns noticed: Identity tied to motion. Blockers: Calendar until Sep 11. How is this actually resolved in your life?

*Reflection:* "The pattern is: I stop moving, then shame about stopping, then identity crisis. The solution isn't harder — it's permission to pause until Sep 11, then restart as a daily practice, not an achievement."

## Implementation Files

- `lib/bot_army_companion/para_client.ex` — NATS client for PARA read/write
- `lib/bot_army_companion/reflection_history.ex` — Parse and summarize prior reflections
- `lib/bot_army_companion/handlers/heartbeat_handler.ex` — Enhanced with `enhance_query_with_history/2`

## Testing

```bash
cd ~/code/bots/bot_army_companion

# Run unit tests (all pass)
mix test

# Manual smoke test (once deployed)
# Trigger a reflection, then check that the next reflection includes prior context
nats request --server nats://localhost:4223 companion.reflection '{}' --timeout 5s
```

## Future Enhancements

1. **Content extraction** — Parse reflection body text (not just filenames) to extract themes and blockers via regex or LLM
2. **Blocker analysis** — Detect "stuck" patterns (same blocker across 3+ cycles) and escalate
3. **Context summarization** — For angles with many reflections, use an LLM to summarize the chain
4. **Per-angle metadata** — Track which angles are "converging" (arriving at resolution) vs. "circling" (repeating), and adjust prompt strategy
