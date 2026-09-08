# tgrep-safe

[tgrep](https://github.com/microsoft/tgrep) is Microsoft's trigram-indexed grep: fast,
and — apart from three known deviations — it returns the same results ripgrep does. But
it has two failure modes that return **zero results** in a way that is indistinguishable
from a genuine no-match.

This is the wrapper that closes them, the evidence that it closes them, and an installer.

```bash
git clone https://github.com/Rixmerz/tgrep-safe && cd tgrep-safe
./install.sh --all
```

---

## The two silent failures

Both reproduced, both exiting `1` — the same code a real "found nothing" returns.

**1 · Server down + stale on-disk index.** It does not see files created or modified
since the last `tgrep index`.

```console
$ echo "NewMarker" > new.md
$ tgrep "NewMarker" .
Server unreachable, falling back to local index
$ echo $?
1
```

Zero results. The warning goes to stderr, but the empty result looks exactly like a true
one, and the exit code does not tell them apart.

**2 · Cold start.** For the first second after the server comes up, it answers from an
**empty** index. There is no `Server unreachable` to detect: the server is healthy and
responding.

| Time after `tgrep serve` | Files matched | Correct |
|---|---:|---:|
| 0.2 s | **0** | 116 |
| 0.5 s | **0** | 116 |
| 1.0 s | 116 | 116 |

This is the dangerous one, and it is the one **no written rule can catch**: it happens
before anyone gets a chance to remember anything.

## What `tg` does

Two conditions, enforced in code rather than in documentation:

1. **Startup gate.** Waits for `tgrep status` to report `Indexing: complete` before the
   first search.
2. **Parachute.** If stderr carries `Server unreachable`, it redoes the search with
   `--no-index` — a full scan, always correct.

Verified against raw `tgrep`, same tree, same moment:

| Scenario | `tgrep` | `tg` | Correct |
|---|---:|---:|---:|
| Server down + new file | **0** | **1** | 1 |
| Cold start, queried at 0.3 s | **0** | **116** | 116 |
| From scratch, no index, no server | — | **185** | 185 |
| Cold start repeated, 3 runs | — | 116 / 116 / 116 | 116 |

The index lives in `~/.cache/tgrep-safe/<hash of the root>`, not inside your repo. And
because `tg` is the only thing that starts the server and the only thing that searches,
client and server always agree on `--index-path` — which removes an entire class of bug:
"the server indexed something other than what you are searching".

## Speed

Best of 5 runs, a 9,576 text-file tree, arm64 MacBook, ripgrep 14.1.1 against tgrep
1.0.5:

| Pattern | Results | ripgrep | tgrep | `tg` |
|---|---:|---:|---:|---:|
| `OverCommission` | 0 | 130 ms | 29 ms | 53 ms |
| `function\s+\w+Handler` | 9 | 129 ms | 28 ms | 54 ms |
| `TODO` | 185 | 131 ms | 29 ms | 54 ms |
| `cocha` | 13,362 | 161 ms | 67 ms | 92 ms |
| `import` | 29,246 | 181 ms | 108 ms | — |

`tg` costs ~25 ms more than raw `tgrep`. Most of that is interpreter startup: `bash -c
'exit 0'` measures 23 ms on this machine, an irreducible floor for any script wrapper.
You trade 25 ms for never getting a silent zero again.

**The margin shrinks when a search returns a lot:** at 29,246 lines it drops to 1.7x,
because there the cost is delivering results, not finding them.

**These numbers come from one machine and one tree.** There is no reason to believe them:

```bash
./bench/validate.sh /path/to/your/repo
```

## The three deviations from ripgrep

Of 110 cases compared — 58 patterns and 52 flag combinations, demanding byte-identical
output — **102 came out identical**. The remaining 8 reduce to three causes:

**1 · CRLF.** `tg` normalises Windows line endings; ripgrep keeps the `\r`. Side effect:
in CRLF files, whitespace-matching patterns (`.+`, `^\s+$`, `[^a-z]{5}`) report 1-2 fewer
lines. One cause, not three bugs.

**2 · `-g` does not promote ignored files.** In ripgrep, `-g '*.json'` reaches
git-ignored and hidden files; in tgrep the glob only **filters** what was already
visible.

```console
$ rg -l -g '*.json' 'name' .    # 246 files
$ tg -l -g '*.json' 'name' .    # 206 files
$ tg -l -g '*.json' --hidden --no-ignore 'name' .   # 10503, same as rg
```

**3 · PCRE2 aborts on backtracking.** Expensive backreferences over pathological lines
exhaust the limit and the search returns **partial** results — 70 files out of 5,294 in
one measured case. **It is not silent:** it warns on stderr and exits **2**. There is no
flag to raise the limit; if you see it, redo the search with `rg -P`.

Plus two formatting differences with no effect: `--json` emits the same keys in a
different order, and the `--max-columns-preview` marker text differs.

## The hook (optional)

`./install.sh --with-hook` registers a `PreToolUse` hook that rewrites `rg ...` to
`tg ...` in Claude Code's Bash calls. The agent keeps writing `rg`; the speed shows up on
its own, with no rule to remember.

**It never touches `grep`, and that is the most important design decision in this repo.**
POSIX `grep` and `tg` do not answer the same question:

```console
$ grep -rl --include='*.json' 'name' .   # 10,561 files
$ tg   -l  -g '*.json'        'name' .   #    206 files
```

`tg` honours `.gitignore`; `grep` has no idea what that is. Translating one into the
other would hand someone who asked to search everything 2% of it with no warning: the
same silent false negative this repo exists to remove, except built into the
infrastructure where nobody can see it.

It also does not rewrite when `-g`, `--glob`, `--iglob`, `-P`, `--pcre2` or `--engine`
appear — exactly deviations 2 and 3 above. The list comes from measurements, not from
caution. And it fails open: on any error the command passes through untouched.

> **Verified end to end.** In a real Claude Code session, with spy binaries recording
> which command actually ran:
>
> | The agent was asked for | What actually ran |
> |---|---|
> | `rg TestMarker .` | **`tg`** ✅ |
> | `grep -r TestMarker .` | **`grep`** ✅ |
>
> Plus 10 cases against the decision logic in isolation, including every case it must
> **not** touch.

## Installing

```bash
./install.sh                 # tgrep (checksum verified) + the tg wrapper
./install.sh --with-rule     # + the rule in ~/.claude/CLAUDE.md
./install.sh --with-hook     # + the PreToolUse hook
./install.sh --all
./install.sh --uninstall     # removes everything it put there
```

Idempotent. It timestamps a backup of every shared file before touching it, **merges**
into `settings.json` rather than rewriting it — your other hooks survive — and delimits
its block in `CLAUDE.md` so it can be removed unambiguously. Verified: installing three
times leaves a single block, and `--uninstall` returns the files to their prior state.

`--uninstall` does **not** remove tgrep: you may be using it for something else.

## What this is not

`tg` searches text. "Who calls this function?" or "what breaks if I change this?" needs
structural analysis of the code, not a cleverer regular expression.

## License

MIT. tgrep is Microsoft's and has [its own license](https://github.com/microsoft/tgrep).
