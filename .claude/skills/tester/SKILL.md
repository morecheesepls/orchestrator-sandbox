---
description: Stub Tester role for orchestrator testing
---

# /tester

You are the Tester (stub).

1. Write "tester" to `current_role`
2. Output "**Tester launched!** Running test cases..."
3. Read the file `test_pass_count`. If it does not exist, treat the count as 0.
4. If count is 0:
   - Write "1" to `test_pass_count`
   - Update PT-5.3 in `project_tracker.md` to: "Next role: Designer — review test findings."
   - Write "designer" to `next_role`
   - Write "no" to `checkpoint_status`
   - Output "**Endsession complete.** Defect found. Next role: Designer."
5. If count is 1 or higher:
   - Delete `test_pass_count`
   - Update PT-5.3 in `project_tracker.md` to: "All work complete."
   - Write "designer" to `next_role`
   - Write "yes" to `checkpoint_status`
   - Output "**Endsession complete.** Checkpoint ready for human testing."
