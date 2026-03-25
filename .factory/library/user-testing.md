# User Testing Knowledge

## Surfaces

- `cli-docker-validation`: repository user surface is CLI/Docker/GitHub Actions artifacts, not a browser UI.

## Setup

- No long-running local app service is required for this milestone.
- Assertions are validated via workflow config inspection plus recorded validation evidence artifacts under:
  - `/home/sandbox/.factory/missions/d833085f-a59f-47f7-82d4-eac8ae14791a/handoffs/`
  - `/home/sandbox/kairos-init/.factory/library/arm64-boot-deferral-evidence.md`
  - `/home/sandbox/kairos-init/.github/workflows/test.yml`

## Validation Concurrency

- `cli-docker-validation`: max concurrent validators = `2`
  - Rationale: validators are evidence/CLI-driven and can run in parallel when they avoid writing shared files.
  - Isolation rule: each validator writes to its own flow report and its own mission evidence subdirectory.

## Flow Validator Guidance: cli-docker-validation

- Stay inside assigned assertion set and mission boundaries.
- Use read-only validation when possible (artifact inspection, log checks, workflow checks).
- If a command is needed, prefer lightweight commands that do not mutate repository logic.
- Write report JSON only to assigned flow path.
- Save any generated evidence under assigned mission evidence directory only.
- Include in report:
  - `assertions`: array of `{id, status, reason, evidence}`
  - `frictions`: array of strings
  - `blockers`: array of strings
  - `toolsUsed`: array of strings
