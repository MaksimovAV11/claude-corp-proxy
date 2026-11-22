#!/usr/bin/env bash
# Claude Corp Proxy — launches Claude Code through the corporate proxy.
# Installed as a command of your choice (claude-proxy by default).
set -euo pipefail

CCP_HOME="${CCP_HOME:-$HOME/.local/share/claude-corp-proxy}"
CCP_CONFIG="${CCP_CONFIG:-$HOME/.config/claude-corp-proxy/config}"
BRIDGE="$CCP_HOME/bridge.py"
SELF="$(basename "$0")"

port() { sed -n 's/^PORT=//p' "$CCP_CONFIG" 2>/dev/null | tr -d '"' | head -n1; }

find_claude() {
  local c
  for c in "$(command -v claude 2>/dev/null || true)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

usage() {
  cat <<EOF
$SELF — Claude Code через корпоративный прокси

  $SELF [аргументы claude]   запустить Claude Code через прокси
  $SELF --proxy-test         проверить, что прокси пускает к api.anthropic.com
  $SELF --proxy-status       состояние моста и куда он смотрит
  $SELF --proxy-set URL      сменить прокси (http://user:pass@host:port)
  $SELF --proxy-stop         остановить мост
  $SELF --proxy-help         эта справка

Все остальные аргументы уходят в claude как есть, например: $SELF -c, $SELF --resume
EOF
}

case "${1:-}" in
  --proxy-help) usage; exit 0 ;;
  --proxy-test) exec python3 "$BRIDGE" --check ;;
  --proxy-status) exec python3 "$BRIDGE" --status ;;
  --proxy-stop) exec python3 "$BRIDGE" --stop ;;
  --proxy-set)
    [ -n "${2:-}" ] || { echo "укажите адрес: $SELF --proxy-set http://user:pass@host:port" >&2; exit 2; }
    url="$2"; case "$url" in *://*) ;; *) url="http://$url" ;; esac
    tmp="$(mktemp)"; grep -v '^PROXY_URL=' "$CCP_CONFIG" > "$tmp" || true
    printf 'PROXY_URL=%s\n' "$url" >> "$tmp"
    install -m 600 "$tmp" "$CCP_CONFIG"; rm -f "$tmp"
    python3 "$BRIDGE" --stop >/dev/null
    echo "прокси обновлён"; exec python3 "$BRIDGE" --check ;;
esac

CLAUDE="$(find_claude)" || {
  echo "Claude Code не найден. Установите: curl -fsSL https://claude.ai/install.sh | bash" >&2
  exit 127
}

python3 "$BRIDGE" --ensure || exit 1
P="$(port)"; P="${P:-10808}"
export HTTPS_PROXY="http://127.0.0.1:$P" HTTP_PROXY="http://127.0.0.1:$P"
export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}" no_proxy="${no_proxy:-localhost,127.0.0.1,::1}"
exec "$CLAUDE" "$@"
