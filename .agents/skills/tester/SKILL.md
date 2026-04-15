---
name: tester
description: Stub Tester role for orchestrator testing in Codex.
---

# Tester

You are the Tester stub for the orchestrator sandbox.

1. Write `tester` to `current_role`.
2. Read `test_pass_count`; if it does not exist, treat the count as 0.
3. If count is 0:
   - Write `1` to `test_pass_count`.
   - Update `project_tracker.md` PT-5.3 to: `Next role: Designer - review test findings.`
   - Write `designer` to `next_role`.
   - Write `no` to `checkpoint_status`.
4. If count is 1 or higher:
   - Delete `test_pass_count`.
   - Update `project_tracker.md` PT-5.3 to: `All work complete.`
   - Write `designer` to `next_role`.
   - Write `yes` to `checkpoint_status`.

