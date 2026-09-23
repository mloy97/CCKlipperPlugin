# Planning docs: CommunityCAD for Klipper

Planning for the CommunityCAD plugin for Klipper printers (Mainsail and Fluidd). Start here.

| File | What it is | Read it when |
|---|---|---|
| `execution-plan.md` | **The source of truth.** Decisions, architecture, phases, endpoints, tables, acceptance criteria, and the rules Claude Code works under. | Before any work on this project |
| `feature-overview.md` | What the plugin does and why, in non-technical terms | For context on what a feature is for |
| `api-audit.md` | Audit of the CommunityCAD API against the plugin's needs, with file and line references (2026-09-21) | When touching the API |
| `phase0-spike-report.md` | Results of the UI injection spike (2026-09-22), including every gotcha the installer must handle | Phase 3, the plugin installer |

## Rules

- Where this plan and the audit disagree, the execution plan wins.
- Where the plan is silent, follow existing codebase conventions and keep it simple.
- At the end of each phase, update `execution-plan.md`: mark the phase done, and record anything that changed from the plan and why.
- Decisions in section 1 of the plan are settled. Changing one needs Miguel's sign-off.

## Status

Phase 0 is done. Phase 1 is next. The current status table is at the bottom of `execution-plan.md`.
