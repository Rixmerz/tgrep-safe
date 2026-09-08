#!/usr/bin/env bash
#
# tgrep-safe — installer. Idempotent: running it twice duplicates nothing.
#
#   ./install.sh                 tgrep + the tg wrapper
#   ./install.sh --with-rule     + the rule in ~/.claude/CLAUDE.md
#   ./install.sh --with-hook     + the PreToolUse hook (rg -> tg) in ~/.claude/settings.json
#   ./install.sh --all           all three
#   ./install.sh --uninstall     removes everything it put there
#
# Nothing is written without a prior backup, and everything that touches a shared file
# (CLAUDE.md, settings.json) is delimited so it can be removed unambiguously.

set -euo pipefail

VERSION_TGREP="v1.0.5"
BIN_DIR="${TGREP_SAFE_BIN:-$HOME/.local/bin}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MARCA_INI="<!-- tgrep-safe:inicio -->"
MARCA_FIN="<!-- tgrep-safe:fin -->"
ID_HOOK="tgrep-safe:rg-to-tg"

con_regla=0; con_hook=0; desinstalar=0
for arg in "$@"; do
  case "$arg" in
    --with-rule) con_regla=1 ;;
    --with-hook) con_hook=1 ;;
    --all)       con_regla=1; con_hook=1 ;;
    --uninstall) desinstalar=1 ;;
    -h|--help)   sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

info() { printf '  %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }

# ── backup ───────────────────────────────────────────────────────────────────
# A timestamped backup, not one that overwrites itself: if the installer runs twice,
# the second backup must not destroy the original state.
backup() {
  [ -f "$1" ] || return 0
  cp "$1" "$1.tgrep-safe-bak.$(date +%Y%m%d%H%M%S)"
}

# ── settings.json ────────────────────────────────────────────────────────────
# Merged with Python, never with sed or a template. A real settings.json already
# carries hooks from other plugins; writing the whole file would erase them, and the
# user would find out their enforcer stopped working weeks later.
touch_settings() {  # touch_settings <add|remove>
  local action="$1" file="$CLAUDE_DIR/settings.json"
  mkdir -p "$CLAUDE_DIR"
  [ -f "$file" ] || echo '{}' > "$file"
  backup "$file"
  ACCION="$action" ARCHIVO="$file" HOOK_CMD="$BIN_DIR/tgrep-safe-rg-to-tg" ID="$ID_HOOK" python3 - <<'PY'
import json, os, sys

archivo = os.environ["ARCHIVO"]
accion  = os.environ["ACCION"]
cmd     = os.environ["HOOK_CMD"]
marca   = os.environ["ID"]

with open(archivo) as f:
    d = json.load(f)

hooks = d.setdefault("hooks", {})
pre   = hooks.setdefault("PreToolUse", [])

# Identified by its command, not by position: the user may have reordered
# their hooks between one run and the next.
def is_ours(entry):
    return any(marca in h.get("command", "") for h in entry.get("hooks", []))

pre[:] = [e for e in pre if not is_ours(e)]

if accion == "add":
    pre.append({
        "matcher": "Bash",
        "hooks": [{
            "type": "command",
            # The marker rides in a comment on the command itself so it can be
            # recognised at uninstall time without depending on the path, which
            # changes between machines.
            "command": f"{cmd}  # {marca}",
            "timeout": 5,
        }],
    })

if not pre:
    hooks.pop("PreToolUse", None)
if not hooks:
    d.pop("hooks", None)

with open(archivo, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
}

# ── CLAUDE.md ────────────────────────────────────────────────────────────────
touch_rule() {  # touch_rule <add|remove>
  local action="$1" file="$CLAUDE_DIR/CLAUDE.md"
  mkdir -p "$CLAUDE_DIR"; touch "$file"; backup "$file"
  # The previous block is always removed first: that makes "add" idempotent and
  # "remove" the same path without the append.
  python3 - "$file" "$MARCA_INI" "$MARCA_FIN" <<'PY'
import sys, re
archivo, ini, fin = sys.argv[1], sys.argv[2], sys.argv[3]
texto = open(archivo).read()
patron = re.compile(re.escape(ini) + r".*?" + re.escape(fin) + r"\n?", re.S)
open(archivo, "w").write(patron.sub("", texto).rstrip() + "\n" if patron.search(texto) else texto)
PY
  if [ "$action" = "add" ]; then
    { [ -s "$file" ] && echo; echo "$MARCA_INI"; cat "$AQUI/rules/tgrep.md"; echo "$MARCA_FIN"; } >> "$file"
  fi
}

# ── uninstall ────────────────────────────────────────────────────────────────
if [ "$desinstalar" = 1 ]; then
  echo "tgrep-safe — uninstalling"
  rm -f "$BIN_DIR/tg" "$BIN_DIR/tgrep-safe-rg-to-tg" && ok "binaries removed from $BIN_DIR"
  [ -f "$CLAUDE_DIR/settings.json" ] && touch_settings remove && ok "hook removed from settings.json"
  [ -f "$CLAUDE_DIR/CLAUDE.md" ] && touch_rule remove && ok "rule removed from CLAUDE.md"
  info "tgrep is NOT removed: you may be using it for something else."
  info "To remove it: rm $BIN_DIR/tgrep  ·  indexes live in ~/.cache/tgrep-safe"
  exit 0
fi

# ── 1. tgrep ─────────────────────────────────────────────────────────────────
echo "tgrep-safe — installing"
mkdir -p "$BIN_DIR"

if command -v tgrep >/dev/null 2>&1; then
  ok "tgrep already present: $(tgrep --version)"
else
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  destino="aarch64-apple-darwin.tar.gz" ;;
    Darwin-x86_64) destino="x86_64-apple-darwin.tar.gz" ;;
    Linux-aarch64) destino="aarch64-unknown-linux-musl.tar.gz" ;;
    Linux-x86_64)  destino="x86_64-unknown-linux-musl.tar.gz" ;;
    *) echo "  unsupported platform: $(uname -s)-$(uname -m)" >&2
       echo "  install tgrep manually: https://github.com/microsoft/tgrep" >&2; exit 1 ;;
  esac
  archivo="tgrep-${VERSION_TGREP}-${destino}"
  base="https://github.com/microsoft/tgrep/releases/download/${VERSION_TGREP}"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  info "downloading $archivo"
  curl -fsSL -o "$tmp/t.tar.gz" "$base/$archivo"
  curl -fsSL -o "$tmp/sums.txt" "$base/checksums.txt"

  # The checksum is ALWAYS verified and a mismatch aborts. A binary that is going to
  # intercept every search you run is not installed by "trusting the network".
  esperado="$(grep " $archivo\$" "$tmp/sums.txt" | awk '{print $1}')"
  if command -v shasum >/dev/null 2>&1; then real="$(shasum -a 256 "$tmp/t.tar.gz" | awk '{print $1}')"
  else real="$(sha256sum "$tmp/t.tar.gz" | awk '{print $1}')"; fi
  if [ -z "$esperado" ] || [ "$esperado" != "$real" ]; then
    echo "  checksum MISMATCH. expected=$esperado got=$real" >&2; exit 1
  fi
  ok "checksum verified"
  tar xzf "$tmp/t.tar.gz" -C "$tmp"
  install -m 755 "$tmp/tgrep" "$BIN_DIR/tgrep"
  [ "$(uname -s)" = "Darwin" ] && xattr -d com.apple.quarantine "$BIN_DIR/tgrep" 2>/dev/null || true
  ok "tgrep $VERSION_TGREP in $BIN_DIR"
fi

# ── 2. the wrapper ───────────────────────────────────────────────────────────
install -m 755 "$AQUI/bin/tg" "$BIN_DIR/tg"
ok "tg wrapper in $BIN_DIR"

# ── 3. the rule (optional) ───────────────────────────────────────────────────
if [ "$con_regla" = 1 ]; then touch_rule add; ok "rule in $CLAUDE_DIR/CLAUDE.md"; fi

# ── 4. the hook (optional) ───────────────────────────────────────────────────
if [ "$con_hook" = 1 ]; then
  install -m 755 "$AQUI/hooks/rg-to-tg.py" "$BIN_DIR/tgrep-safe-rg-to-tg"
  touch_settings add
  ok "PreToolUse hook in $CLAUDE_DIR/settings.json (restart Claude Code)"
fi

echo
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) info "⚠  $BIN_DIR is not on your PATH." ;; esac
info "Try it:  tg \"something\" ."
