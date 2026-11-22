#!/usr/bin/env bash
# Claude Corp Proxy — удаление. Сам Claude Code не трогается.
set -euo pipefail
CCP_HOME="$HOME/.local/share/claude-corp-proxy"
CONF_DIR="$HOME/.config/claude-corp-proxy"
STATE_DIR="$HOME/.cache/claude-corp-proxy"
BIN_DIR="$HOME/.local/bin"

[ -f "$CCP_HOME/bridge.py" ] && python3 "$CCP_HOME/bridge.py" --stop >/dev/null 2>&1 || true

for cmd in $(sed -n 's/^COMMANDS=//p' "$CONF_DIR/config" 2>/dev/null); do
  if [ -L "$BIN_DIR/$cmd" ] && [ "$(readlink "$BIN_DIR/$cmd")" = "$CCP_HOME/launcher.sh" ]; then
    rm -f "$BIN_DIR/$cmd"; echo "удалена команда $cmd"
  fi
done

rm -rf "$CCP_HOME" "$CONF_DIR" "$STATE_DIR"
# Строку PATH в ~/.bashrc не трогаем: в ~/.local/bin живёт и сам Claude Code.
echo "Claude Corp Proxy удалён (настройки и сохранённый прокси стёрты)."
