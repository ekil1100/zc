# Test Rule Provider Missing-Only Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `zc test` download missing rule-provider files but skip interval-based refresh when a local provider cache already exists.

**Architecture:** Keep rule-provider preparation centralized in `src/config.zig`, but add a small sync-policy enum so callers can choose between eager sync and missing-only sync. Thread that policy through config-loading helpers in `src/main.zig`, and make `zc test` use missing-only while other commands keep eager behavior.

**Tech Stack:** Zig 0.15.x, std.testing, existing CLI/config loading pipeline

---

### Task 1: Add failing coverage for provider sync policy

**Files:**
- Modify: `src/config.zig`
- Modify: `src/main.zig`
- Test: `src/config.zig`
- Test: `src/main.zig`

- [ ] **Step 1: Write the failing test**

Add unit coverage for two cases:
1. existing rule-provider cache + stale mtime + missing-only policy => file content must stay unchanged
2. helper that maps `zc test` to missing-only policy => command-specific behavior is explicit

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/like/workspace/zc/.worktrees/fix-test-provider-missing-only && zig build test --summary all`
Expected: FAIL in the new coverage because current code always refreshes stale provider files and `zc test` still uses eager sync.

- [ ] **Step 3: Write minimal implementation**

Introduce a rule-provider sync policy enum and thread it into runtime config loading so only `zc test` selects missing-only.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/like/workspace/zc/.worktrees/fix-test-provider-missing-only && zig build test --summary all`
Expected: PASS for new and existing tests except unrelated known baseline failures, if still present.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig src/main.zig docs/cli/spec.md docs/config/override.md TASKS.md docs/superpowers/plans/2026-03-22-test-rule-provider-missing-only.md
git commit -m "fix: avoid refreshing cached rule providers during zc test"
```

### Task 2: Update user-facing docs and task tracking

**Files:**
- Modify: `docs/cli/spec.md`
- Modify: `docs/config/override.md`
- Modify: `TASKS.md`

- [ ] **Step 1: Write the doc/task updates**

Document that `zc test` only downloads missing rule-provider files and does not perform interval refresh of existing cache files.

- [ ] **Step 2: Verify docs reflect behavior**

Re-read the changed sections and ensure they match the implementation boundaries: `test` is missing-only; runtime prep remains eager elsewhere.

- [ ] **Step 3: Commit**

Use the same atomic commit as Task 1 if both tasks land together.
