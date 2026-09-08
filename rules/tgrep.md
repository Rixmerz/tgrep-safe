## Code search: use `tg`

To search for text or a regex, use **`tg`** instead of `grep` or `rg`. It takes the same
flags ripgrep does (`-n -i -w -l -c -t -A/-B/-C -U -o -r`) and returns the same results,
with a trigram index underneath.

```bash
tg "OverCommission" .          # ~2x faster than ripgrep
tg --stats 'pattern' .         # shows selectivity: "candidates: 12/9578"
```

**Do not use raw `tgrep`.** It has two failure modes that return zero results with exit
1, indistinguishable from a genuine no-match: with the server down it does not see files
modified since the last index, and for ~1s after starting it serves an empty index
without warning about anything. `tg` closes both. If you write a file and search for it
immediately, `tg` finds it and `tgrep` does not.

**Three differences against ripgrep, measured across 110 cases:**

1. `tg` normalises CRLF while ripgrep keeps the `\r`. This affects whitespace-matching
   patterns by 1-2 lines.
2. `-g` does **not promote** git-ignored files the way ripgrep does (246 vs 206 files).
   If you need them: `tg -g '*.json' --hidden --no-ignore`.
3. Regexes with expensive backreferences exhaust PCRE2's backtracking limit and return
   **partial** results. It warns on stderr and exits **2** — if you see that, redo the
   search with `rg -P`.

**`tg` searches text.** "Who calls this?" or "what breaks if I change it?" needs
structural analysis, not a cleverer regex.
