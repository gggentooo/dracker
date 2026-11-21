# SynthTracker Changelog

All major changes to `synth-tracker/` must be recorded in reverse-chronological order (newest entry first).

### Entry Format
- **Timestamp:** `YYYY-MM-DD HH:MM:SS KST` (UTC+09:00)
- **Author:** Human developer name or agent model name
- **Affected Files:** Explicit list of created, modified, or deleted paths
- **Description:** Concise summary of the change(s)

---

## [2026-11-21 20:59:47 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `.gitignore` (created at repository root)
  - `synth-tracker/docs/changelog.md` (updated)
- **Description:** Added root `.gitignore` ignoring everything outside `synth-tracker/` plus standard OS, D/LDC2/DUB, Metal/Xcode, and IDE artifacts; verified zero tracked ignored files remained in the index.

## [2026-11-21 20:45:11 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/docs/` (created directory)
  - `synth-tracker/agents.md` (created)
  - `synth-tracker/docs/changelog.md` (created)
- **Description:** Created `synth-tracker/docs/`, authored `synth-tracker/agents.md` at the project root as the agent source-of-truth reference (covering design invariants, directory map, phased implementation checklists with strict exit gates, build/test commands, strict document/DDoc-only comment rules, pure-D FFI policy, and changelog requirements), and initialized `synth-tracker/docs/changelog.md` with its first entry.
