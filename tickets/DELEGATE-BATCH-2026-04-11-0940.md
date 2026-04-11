# Delegation Batch — 2 tickets (sequential)

Run each brief in a **new Copilot Chat session** (fresh context between each).
Stay in the same VS Code window — the brief handles branch switching.

Both tickets touch the companion-app build-status UI and may share code paths.
Running them sequentially (not in parallel worktrees) keeps merge conflicts off
the table — the second ticket will rebase onto main at ship time and deal with
any collisions then.

1. [ ] **TKT-043** "Companion Build tab stuck on 'Building…' after build completes"
       Branch: `ticket/tkt-043-companion-build-tab-stuck` (already created from main)
       Run: `/run-brief tickets/TKT-043.full.brief.md`
       Wait for: "Brief executed: TKT-043.full.brief.md"

2. [ ] **TKT-044** "Companion Projects detail view doesn't reactively update build status"
       Branch: `ticket/tkt-044-companion-projects-detail-not-reactive` (already created from main)
       **Start a NEW Copilot Chat session first!** (clears the previous ticket's context)
       Run: `/run-brief tickets/TKT-044.full.brief.md`
       Wait for: "Brief executed: TKT-044.full.brief.md"

When both are done, come back to Claude Code and run:

```
/ticket-collect TKT-043 TKT-044
```

Claude will review both branches and report back.
