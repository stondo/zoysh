# PTY scrollback capture: design decision

Written 2026-08-25 for the `feat/pty-scrollback` branch, before
implementation, as required by the feature plan. Timebox: one hour of
investigation; the outcome is a scope decision, not a full terminal
multiplexer design.

## Question

Should zoysh capture terminal scrollback by (A) hosting the session inside
zsh's own `zpty` module, (B) porting yosh's fork/exec PTY proxy pair into
the native module, or (C) capturing only the output of commands zoysh
itself queues, without any PTY?

## What yosh does

Yosh forks a PTY proxy at shell startup: the user's shell runs inside a
PTY owned by the yo runtime, and everything that passes through (both
sides) is kept in a bounded ring. This works because yosh IS a forked
bash; the wrapper is invisible by construction. See
`readline-8.2.13/yo.c` (`yo_pty_init`).

## Option A: zpty-hosted proxy shell

`zsh/zpty` allocates a pseudo-terminal and runs a program inside it. To
capture the user's session we would run a second interactive shell inside
that pty, present its output, and forward keystrokes; that means writing
a small terminal multiplexer inside zsh: resize handling (WINCH forwarding
and re-wrapping), signal forwarding, bracketed paste and other ZLE
protocols across the boundary, and a redraw loop. Every one of these is a
known source of glitches in existing tools that try it. Verdict: rejected
for v1; the complexity and breakage risk is wildly out of proportion to
the value of context capture.

## Option B: fork/exec PTY pair in the native module

The honest port of yosh's approach. It requires the native module to wrap
the session at shell startup: the module would have to be loaded before
the prompt ever appears, re-parent the user's shell under a PTY, and then
keep a ring of everything. Two blockers: the module is experimental and
opt-in (asking new users to boot their shell inside it is not tenable
yet), and the same multiplexer problems as option A apply to resize and
redraw, just in C instead of zsh. Verdict: the right Phase 2 follow-up
once the module is proven, not v1.

## Option C: capture what zoysh queues (chosen for v1)

zoysh already walks the user through multi-step plans: it prefills each
step command for review. When `scrollback_enabled 1`, the prefill wraps
the step as `zoysh-run <command>`: a shell function that tees the command
and its output (stdout plus stderr) into a bounded ring file under the
state directory, preserves the command's exit status, and trims the ring
to `scrollback_bytes`. The ring is injected as context into subsequent
`yo` calls. No PTY, no session wrapping, zero cost when disabled (the
wrapper is only applied when the directive is on; no hooks are
registered).

Consequences, stated plainly in the README:

- The wrapped command is visible in the buffer before it runs; the user
  can see exactly what will be captured and simply press Enter.
- Anything not run through a plan step (or a manual `zoysh-run`) is not
  captured. Ambient whole-terminal scrollback remains a Yosh-only feature
  until option B lands in the native module.

## Privacy

Captured output is stored locally under the state directory and is sent to
the configured API endpoint as part of the context of later `yo` calls.
The README keeps this next to the `scrollback_enabled` directive.
