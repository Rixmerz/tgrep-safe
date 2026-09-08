#!/usr/bin/env python3
"""PreToolUse: rewrites `rg ...` to `tg ...` in Bash tool calls.

The point is that the agent never needs to know tgrep exists. It keeps writing `rg`;
the speed shows up on its own.

WHAT IT DOES NOT DO, AND WHY THAT MATTERS MORE
----------------------------------------------

**It never touches `grep`.** That is the obvious temptation and it is the trap. POSIX
`grep` and `tg` do not answer the same question: `tg` honours .gitignore and `grep` has
no idea what that is. Measured on a real tree, same search:

    grep -rl --include='*.json' 'name' .   -> 10,561 files
    tg   -l  -g '*.json'        'name' .   ->    206 files

Swapping one for the other would hand someone who asked to search everything 2% of it,
with no warning at all. That is a silent false negative built into the infrastructure,
where nobody can see it. `rg` -> `tg` is legitimate: that is the equivalence validated
across 110 cases.

**It does not rewrite when any of these flags appear.** This is not generic caution --
each one comes from a measured deviation against ripgrep.

  -g / --glob / --iglob / --glob-case-insensitive
      In ripgrep a glob PROMOTES git-ignored files; in tgrep it only filters what was
      already visible. 246 files against 206 on the same tree. Rewriting here would
      silently change the result, which is precisely what this hook exists not to do.

  -P / --pcre2 / --engine
      Expensive backreferences over pathological lines exhaust tgrep's backtracking
      limit and the search returns PARTIAL results (measured: 70 files out of 5,294).
      It warns on stderr and exits 2, so it is not silent -- but introducing that
      difference is not a hook's job.

**It only rewrites an `rg` invocation that opens the command.** Properly parsing shell --
pipes, subshells, nested quoting -- to find every `rg` is a worse source of bugs than
the problem it solves. An `rg` in the middle of a pipeline is left alone: correct and
not accelerated beats fast and wrong.

**It fails open.** Any exception, any doubt: the command is approved untouched. A broken
hook must never break a session.
"""

import json
import shutil
import sys

# Flags where tg and rg diverge in measured ways. See the docstring.
EXCLUDED_FLAGS = {
    "-g", "--glob", "--iglob", "--glob-case-insensitive",
    "-P", "--pcre2", "--engine",
}


def approve_untouched() -> None:
    """Empty output lets the normal permission flow continue."""
    print("{}")
    sys.exit(0)


def has_excluded_flag(command: str) -> bool:
    """Match flags by token, not by substring.

    A `--glob` inside a search pattern ('find --glob in the text') is not a flag, and
    treating it as one would only disable the hook too often. Compare whole tokens, and
    also the `--engine=pcre2` form, which stays glued together after a split.
    """
    for token in command.split():
        if token in EXCLUDED_FLAGS:
            return True
        if token.split("=", 1)[0] in EXCLUDED_FLAGS:
            return True
    return False


def main() -> None:
    try:
        event = json.load(sys.stdin)
    except Exception:
        approve_untouched()

    try:
        if event.get("tool_name") != "Bash":
            approve_untouched()

        tool_input = event.get("tool_input") or {}
        command = tool_input.get("command")
        if not isinstance(command, str) or not command.strip():
            approve_untouched()

        # With no `tg` installed there is nothing to rewrite. Rewriting anyway would
        # turn every search into "command not found", which is worse than not speeding
        # anything up.
        if shutil.which("tg") is None:
            approve_untouched()

        stripped = command.lstrip()
        # Only an `rg` invocation that OPENS the command. `rg` as an argument to something
        # else, or inside a pipeline, is left alone.
        if not (stripped.startswith("rg ") or stripped == "rg"):
            approve_untouched()

        if has_excluded_flag(stripped):
            approve_untouched()

        indent = len(command) - len(stripped)
        rewritten = command[:indent] + "tg" + stripped[2:]

        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": {**tool_input, "command": rewritten},
            }
        }))
        sys.exit(0)

    except Exception:
        # Explicit fail-open: see the docstring.
        approve_untouched()


if __name__ == "__main__":
    main()
