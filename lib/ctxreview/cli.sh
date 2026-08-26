#!/usr/bin/env bash

usage() {
  cat <<EOF
$SELF — fan a context pack out to four reviewer panes in a Herdr review workspace

USAGE
  $SELF run --legs LIST [--base REF] [--label TEXT] [--dir DIR]

OPTIONS
  --base REF    Diff base. Default: ctxpack's own (merge-base with default branch).
  --legs LIST   Required comma-separated subset of: kimi,grok,sol,opus
  --label TEXT  Tab label. Default: "review: <branch>"
  --dir DIR     Where pack/prompt/results go. Default: a fresh mktemp -d.
  --dry-run     Build the pack and prompt, print the plan, spawn nothing.
  --force       Ship a prompt over the size cap anyway (default cap 400000 bytes).
  --max-bytes N Change the cap.
  --focus TOPIC Run a FOCUSED round. Matches TOPIC against the lens corpus (id,
                title, body; falls back to a stem) and inlines those lenses in
                FULL — a normal pack only lists titles. The reviewers are told to
                report only that class, to park anything else in a one-line list,
                and to say explicitly when they find nothing.
                An unmatched topic is refused, not run unfocused: "found nothing"
                must not be confusable with "the corpus has no checks for this".
  --again       Retire the previous review workspace for this repo, then run a
                fresh round against the current diff. Refuses while a prior leg
                is still working. New legs are deliberately blind to the last
                round: a leg shown prior findings drifts toward confirming them.
  --herdr-session NAME
                Use NAME for the isolated Herdr session instead of generating
                one. Requires Herdr 0.8+. The name is persisted with the run.
  --session ID  Parent Codex/Claude session that owns this round. Defaults to
                CTXREVIEW_SESSION_ID, CODEX_THREAD_ID, or CLAUDE_SESSION_ID.
                Ownership is persisted with each reviewer runtime session so a
                session-end hook can close only this session's review panes.

  --sessions [ID]
                List persisted review rounds, optionally for one parent session.
  --stats [ID]  Show lifecycle telemetry and current persisted/live state,
                optionally for one parent session.
  --maintain    Run the safe lifecycle manager. It reconciles records whose
                exact resources are already absent, closes owner-ended rounds
                after their legs settle, and closes long-settled rounds after
                the retention window. Owner-ended sessions that remain idle
                beyond their own TTL are hibernated even when Cursor's footer
                is inconclusive. Working, blocked, unknown, moved, or
                label-mismatched resources are never closed.
                  --session ID       one parent session (default: current)
                  --all              every persisted ctxreview round
                  --settled-ttl MIN  fallback retention, default 1440
                  --owner-ended-idle MIN
                                      idle abandonment TTL, default 1440
  --close-session ID
                Capture runtime ids/tails and close settled review workspaces
                owned by ID. Working or blocked legs are left alone.
  --session-ended ID
                Mark the parent session ended and run safe maintenance. The
                SessionEnd hook uses this; the last leg retries cleanup when the
                round settles, and the same pass reconciles fleet stragglers.
  --respawn RUN  Reopen the persisted reviewer conversations for RUN. Named
                Herdr restores the saved layout and native agent sessions.
  --attach RUN LEG
                Resume RUN if needed, then attach this terminal directly to its
                kimi, grok, sol, or opus agent. Detach with ctrl+b q.

  --list        Show review workspaces and their legs with live status. Legs are
                left running while their parent is active so you can keep
                talking to them; lifecycle state shows what still holds a session.
  --close X     Hibernate one persisted RUN, or:
                  --done   every settled review owned by --session (or the
                           current harness session)
                  --all    every safely settled persisted review
                Working, blocked, unknown, or untracked agents are never stopped.
  --consolidate DIR
                Merge the legs' reports into one list, agreement first. Reports
                per-leg parse coverage rather than silently dropping a leg whose
                format it could not read. Groups on file:LINE, never on file
                alone — two findings in a busy file are not a consensus.
  --adjudicate DIR [--commit]
                Close the feedback loop. Without --commit, writes a worksheet of
                the consolidated findings with a blank verdict column. Fill in
                accepted|refuted|deferred plus a reason, then re-run with
                --commit to append to the corpus in the same schema
                \`ctxpack harvest\` writes. A refutation carrying a domain fact is
                what bible rules are made of, and nothing can reconstruct it later.
  --bug TEXT [TOOL]
                File a defect against the TOOLING (default tool: ctxreview).
                Separate channel from --adjudicate: that records verdicts about
                the code under review, this records what is broken in the harness.
                Review legs are told they can file too — a leg that trips over a
                tool defect is the best reporter of it.
                  --run ID           originating review run
                  --leg NAME         originating reviewer leg
                  --session ID       originating parent session
  --bugs [open|fixed|all]   List filed defects (default: open).
  --bug-fixed ID            Mark one fixed.
LEGS
  kimi  Cursor  $CURSOR_KIMI
  grok  Cursor  $CURSOR_GROK
  sol   Codex   $CODEX_SOL
  opus  Claude  $CLAUDE_OPUS_LABEL

All four run as interactive agents in their own pane and stay conversible — ask
one to defend a finding, go deeper, or keep going. Each writes its report to
DIR/<leg>.md, which is the durable copy: a pane retains only about a screenful.

Panes stay open while the parent session is active. Read them, close them early
if desired, or let SessionEnd/retention reclaim them. Each leg writes its report
to DIR/<leg>.md; if one finishes without writing, its terminal tail is captured
to DIR/<leg>.tail.md instead — never over the report, and never as an empty file.

ENVIRONMENT
  CTXREVIEW_KIMI / _GROK / _SOL            override a model id
  CTXREVIEW_OPUS                            override the managed Opus 5 1M default
  CTXREVIEW_CURSOR_SPAWN                     override the Cursor pane helper
  CTXREVIEW_SETTLED_RETENTION_MINUTES       fallback cleanup age (default 1440)
  CTXREVIEW_OWNER_ENDED_IDLE_MINUTES        idle abandonment age (default 1440)
  CTXREVIEW_FAILURE_RATE_TARGET_PERCENT     OKR failure-rate target (default 5)
  CTXREVIEW_NOTIFY=1                        opt into Herdr completion toasts
EOF
}
