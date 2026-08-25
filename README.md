# Companion Bot

Autonomous reflection on Abby's context and system state. Executes reflection cycles via the job scheduler and persists observations to PARA.

## Architecture

**Reflections** are short, focused written reflections on predefined "angles" (perspectives):

- **Angle 0**: Emotional check-in (emotional health, connection, self-compassion)
- **Angle 1**: ADHD/energy patterns (balance, hyperfocus health, transitions)
- **Angle 2**: Bot Army balance (perfectionism, north star alignment)
- **Angle 3**: Life/third pillar (Louiza, Greece trip, running/martial arts)
- **Angle 4**: Fleet health (load-bearing bots, robustness, mini status)
- **Angle 5**: Repo-operability/outreach (methodology, sales momentum)
- **Angle 6**: Eir friendship (deepening beyond operator mode)
- **Angle 7**: Loneliness texture (with Louiza, root causes)
- **Angle 8**: Recent wins (celebrating action taken)
- **Angle 9**: System trust (confidence in Bot Army, feedback loops)
- **Angle 10**: Disconnect/recovery (rest, protection, stopping)

## Scheduling

Companion reflections are triggered by **`bot_army_job_scheduler`** on a cron schedule:

```
0 0,6,12,18 * * *  # Runs at 00:00, 06:00, 12:00, 18:00 UTC (6-hour intervals)
```

Override with environment variable:
```bash
JOB_SCHEDULER_COMPANION_HEARTBEAT_CRON="0 */6 * * *"
JOB_SCHEDULER_COMPANION_HEARTBEAT_TIMEOUT="60"  # seconds
```

## Manual Testing

**Trigger a reflection cycle now** (dev NATS):
```bash
make test-reflection
# or
nats request --server nats://localhost:4223 companion.heartbeat '{}' --timeout 60s
```

**Trigger on prod NATS**:
```bash
make test-reflection-prod
# or
nats request --server nats://localhost:4222 companion.heartbeat '{}' --timeout 60s
```

## Observations

Reflections are written to PARA as markdown files:

```
areas/companion/observations/YYYY-MM-DD-angle-N.md
```

**Format**: Timestamp + reflection text + optional "## Abby's reply — ..." section if Abby replied.

**Writing**: Direct NATS `para.fs.write` via `ParaClient.write_file()` in HeartbeatHandler.

## Testing & Development

```bash
# Unit tests
mix test

# Run with specific tag
mix test --only handlers

# Integration tests (with real NATS/DB)
mix test --include integration
```

## Deployment

Standard bot deployment workflow:

```bash
make bump-version  # REQUIRED: every change needs a version bump
make test
make push
make publish-release
make deploy-bot BOT=companion
```

See `~/code/bots/bot_army_infra/Makefile` for operational targets.
