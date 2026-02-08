# Claude Code MCP Idea Orchestration (Draft)

Date: 2026-02-07
Status: DRAFT
Owner: Capacitor

## Summary
Draft plan for a two-way control scheme where Capacitor captures ideas/notes and uses Claude Code (via MCP) to analyze, enrich, prioritize, and eventually implement work. This file records the current proposal for later revisiting.

## Goals
- Make idea capture frictionless and project-scoped.
- Use Claude Code to analyze notes in the background and turn them into actionable work items.
- Detect dependencies between work items, prioritize them, and recommend sequencing.
- Provide a path from analysis to safe, guarded automation of implementation.

## Non-Goals (Phase 1)
- No automatic code changes without explicit approval.
- No PR creation or CI orchestration.
- No multi-agent orchestration beyond a single Claude Code instance.

## Opportunity Map (Capacitor -> Claude Code via MCP)
- Idea capture -> enrichment pipeline (classification, dedupe, acceptance criteria).
- Dependency and impact analysis (files, subsystems, TODOs).
- Prioritization (impact, effort, urgency, user pain).
- Automated execution for low-risk tasks with explicit approvals.
- Team coordination via routing/assignment in later phases.
- Maintenance sweeps (doc drift, flaky tests, cleanup) as scheduled tasks.

## Minimal Data Model

### Entities
1. Project
- id, name, repo_path, default_branch, tech_stack, owners, created_at, updated_at

2. Note (raw capture)
- id, project_id, raw_text, source (ui|voice|clipboard|api), context (file/line/url/screenshot_id)
- captured_by, captured_at, status (new|triaged|discarded)

3. WorkItem (enriched)
- id, project_id, note_id, title, summary
- type (fix|feature|refactor|chore)
- priority (p0-p3), impact (low|med|high), effort (xs-xl)
- tags, acceptance_criteria[], risks[]
- dependencies[] (WorkItem ids), related[]
- status (triaged|planned|in_progress|blocked|done|archived|rejected)
- owner, created_at, updated_at

4. AnalysisArtifact (Claude outputs)
- id, work_item_id, kind (summary|plan|dependency_graph|file_impact|test_plan|patch_summary)
- content (json/text), created_at, model_info

5. ExecutionRun (execution record)
- id, work_item_id, status (queued|running|failed|completed|cancelled)
- started_at, ended_at, logs_uri, diff_uri, tests_uri, result_summary

### Lifecycle
1. Note captured (new)
2. Claude analysis -> WorkItem + artifacts (triaged)
3. Plan + dependencies -> planned
4. Execution run -> in_progress
5. done or blocked

## MCP Contract Draft (Capacitor -> Claude Code)

### Tools
- idea.analyze: Turn a note into a WorkItem draft + artifacts
- idea.dedupe: Find similar notes/work items
- workitem.plan: Generate plan, risks, acceptance criteria
- workitem.dependencies: Identify dependency chain
- workitem.impact: File/subsystem impact assessment
- workitem.implement: Implement changes (guarded)
- workitem.test: Run targeted tests
- repo.scan: Fast scan (TODOs, patterns, refs)

### Resources
- claude://runs/{run_id}/log
- claude://runs/{run_id}/diff
- claude://workitems/{id}/artifacts/{artifact_id}
- claude://projects/{project_id}/repo/state

### Safety Policy (initial)
- workitem.implement requires explicit approval flag from Capacitor
- constraints object to restrict scope:
  - max_diff_lines
  - allow_file_patterns
  - deny_file_patterns
  - commands_allowed

## Phase-1 MVP Plan (Capture -> Enrich -> Prioritize)

### Week 1: Capture + Storage
- Implement Note ingestion in UI/API
- Store minimal metadata and project association
- Manual tags

### Week 2: Enrichment Pipeline
- MCP client in Capacitor
- idea.analyze -> WorkItem + artifacts
- idea.dedupe integration

### Week 3: Prioritization + Dependencies
- workitem.dependencies + workitem.impact
- Simple scoring heuristic (impact, effort, urgency)
- Backlog UI with dependency edges

### Deliverables
- Capture UI + API
- MCP client integration
- Background job queue for analysis
- Ranked backlog view with dependency graph

### Non-Goals (Phase 1)
- No auto changes, no PR creation
- No agent teams or complex orchestration

## Open Questions
- Where should execution authority live (Capacitor vs Claude Code)?
- How strict should guardrails be for workitem.implement?
- What is the minimal repo metadata needed for high-quality planning?
- How should priority be calculated (explicit weights vs model-driven)?

## Next Steps (when revisiting)
- Decide whether to run Claude Code as MCP server directly or via a wrapper.
- Define initial tool JSON schemas and result contracts.
- Identify a minimal UI for review/triage of generated work items.

