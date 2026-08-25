# Feature Specification: Cache Monitor v2 — Subagent & Agent Team Tracking

**Feature Branch**: `006-cache-monitor-subagents`  
**Created**: 2026-04-01  
**Status**: Draft  
**Input**: User description: "cc-cache-monitor v2: subagent and agent team token tracking. Extend the existing cache monitor to aggregate cache metrics from subagent and agent team sessions, show subagent cost indicator in statusline, and add subagent cost breakdown to /usage-details skill."
**Depends on**: `005-cache-monitor` (v1 — implemented, live at github.com/Todmy/cc-cache-monitor)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Subagent cost visibility in statusline (Priority: P1)

A user launches multiple subagents (via the Agent tool) for parallel research or implementation. The statusline shows not only the parent session's cache health, but also the total cost including all active and recently completed subagents. The user can see at a glance how much the entire operation (parent + children) is costing.

**Why this priority**: Subagents are invisible cost multipliers. A parent session might show $2 spent, but 4 parallel subagents each burning $15 would bring the real total to $62. Without aggregation, users have a false sense of what they're spending.

**Independent Test**: Launch a Claude Code session, spawn 2-3 subagents via Agent tool. Verify the statusline shows a `+N subs` indicator with aggregated cost. Verify it updates as subagents complete.

**Acceptance Scenarios**:

1. **Given** a session with active subagents, **When** the statusline renders, **Then** it shows the parent cache status plus a subagent indicator (e.g., `cache: OK 98% $2.34 +3 subs $18.50`).
2. **Given** subagents have completed but their session files exist from the last 5 minutes, **When** the statusline renders, **Then** recently completed subagents are still included in the aggregated cost.
3. **Given** no subagents have been spawned in this session, **When** the statusline renders, **Then** the display is identical to v1 (no subagent indicator shown).
4. **Given** the subagent indicator is present, **When** the user reads the cost, **Then** the parent cost and subagent cost are shown separately (not merged into one number) so the user understands the breakdown.

---

### User Story 2 - Subagent cost breakdown in /usage-details (Priority: P2)

A user runs `/usage-details` and sees a new section that lists each subagent session with its own cache metrics, cost, and duration. This helps the user understand which subagents were expensive and whether their cache was efficient.

**Why this priority**: The statusline shows the aggregate, but to optimize, users need to know which specific subagents were costly. A subagent doing web research might be efficient, while one parsing a large file might have terrible cache performance.

**Independent Test**: Run `/usage-details` on a session that spawned subagents. Verify a "Subagent Sessions" section appears with per-subagent metrics.

**Acceptance Scenarios**:

1. **Given** a session spawned 4 subagents, **When** `/usage-details` runs, **Then** a "Subagent Sessions" section lists each subagent with: description (from Agent tool prompt), duration, call count, cache ratio, cost.
2. **Given** a session with no subagents, **When** `/usage-details` runs, **Then** the subagent section is omitted entirely (not shown as empty).
3. **Given** a subagent had a cache cliff, **When** `/usage-details` runs, **Then** the cliff is flagged in the subagent row.

---

### User Story 3 - Agent Team aggregate monitoring (Priority: P3)

A user working with Agent Teams (multiple coordinating Claude Code instances) can run `/usage-details --team` to see combined metrics across all team members. This covers the experimental CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS feature where multiple sessions coordinate via shared task lists.

**Why this priority**: Agent Teams multiply token consumption by 7-15x compared to single sessions. Without aggregate visibility, the true cost of a team operation is scattered across disconnected session files.

**Independent Test**: Set up an Agent Team with 2-3 members, run a coordinated task. Run `/usage-details --team` and verify all team member sessions appear with aggregate totals.

**Acceptance Scenarios**:

1. **Given** an Agent Team session is active, **When** the user runs `/usage-details --team`, **Then** a table shows each team member session with cache metrics, cost, and role.
2. **Given** team members are in different project directories, **When** `/usage-details --team` runs, **Then** sessions are discovered across all `~/.claude/projects/` subdirectories.
3. **Given** no agent team is active, **When** the user runs `/usage-details --team`, **Then** the system reports that no team sessions were found.

---

### Edge Cases

- What happens when subagent JSONL files are very small (1-2 API calls)? They are reported with status WARM and their actual cost, no cliff detection attempted.
- What happens when subagents complete and their JSONL files are old? Subagents modified more than 10 minutes ago are excluded from the statusline aggregation (but still visible in /usage-details).
- What happens when the hook checks for subagent files but the find operation is slow? A time budget of 50ms is allocated for subagent discovery; if exceeded, the hook falls back to parent-only metrics.
- What happens with Agent Team sessions from a different project? They are discovered by scanning all subdirectories under `~/.claude/projects/`, not just the current project.
- What happens when a subagent's JSONL has no usage data? It's silently excluded from aggregation.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST detect subagent session files by finding JSONL transcripts modified within a configurable time window (default: 5 minutes) that are not the parent session file.
- **FR-002**: System MUST aggregate subagent costs separately from parent session cost in the statusline, showing both values distinctly.
- **FR-003**: System MUST show a subagent count indicator in the statusline when subagents are detected (e.g., `+3 subs`).
- **FR-004**: System MUST omit the subagent indicator entirely when no subagents are detected (backwards compatible with v1).
- **FR-005**: The `/usage-details` skill MUST include a "Subagent Sessions" section listing each detected subagent with: description, duration, call count, cache ratio, cost, and cliff flag.
- **FR-006**: The `/usage-details` skill MUST support a `--team` argument that discovers and aggregates Agent Team sessions across all project directories.
- **FR-007**: Subagent discovery in the hook MUST complete within 50ms to stay within the total 100ms hook budget alongside parent metrics collection.
- **FR-008**: System MUST maintain backwards compatibility — all v1 behavior (statuses, cliff detection, cost calculation, install/uninstall) remains unchanged.
- **FR-009**: System MUST gracefully handle the case where subagent JSONL files have no usage data (skip silently).
- **FR-010**: System MUST exclude subagent files older than the configurable staleness threshold from statusline aggregation (but include them in /usage-details).

### Key Entities

- **Parent Session**: The primary Claude Code session where the user types prompts and receives responses. Identified as the most recently modified JSONL under `~/.claude/projects/`. Already tracked by v1.
- **Subagent Session**: A JSONL transcript created when the parent session spawns an Agent tool call. Lives in a temporary directory or under `~/.claude/projects/`. Identified by modification time proximity to the parent session.
- **Agent Team Member**: A JSONL transcript from an Agent Teams session (experimental). Each team member has its own session file, potentially in different project directories.
- **Aggregate Metrics**: Combined cost, call count, and cache statistics across parent + all detected subagent/team sessions.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can see total cost (parent + subagents) within 300ms of any interaction when subagents are active, preventing "hidden cost" surprise.
- **SC-002**: The subagent indicator appears within 1 API call of the first subagent being spawned.
- **SC-003**: Users can identify which specific subagent consumed the most tokens within 10 seconds of running `/usage-details`.
- **SC-004**: The hook with subagent discovery stays within the 100ms total execution budget (50ms parent + 50ms subagent discovery).
- **SC-005**: All v1 functionality continues to work identically — no regressions for users without subagents.
- **SC-006**: Agent Team aggregate view provides complete cost visibility across all team members within 30 seconds of running the command.

## Assumptions

- Subagent JSONL files follow the same format as parent session files (assistant messages with `usage` fields).
- Subagent sessions are created under `~/.claude/projects/` or in temp directories accessible to the hook.
- The modification time of JSONL files is a reliable indicator of recency (within the 5-minute window).
- Agent Teams feature (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1) uses separate JSONL files per team member.
- The v1 cc-cache-monitor is already installed and functional (this is an extension, not a replacement).
- The performance budget for the hook allows 50ms additional overhead for subagent file discovery beyond the existing parent session processing.
