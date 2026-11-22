#!/usr/bin/env bash
# Claude Corp Proxy — установщик.
#   curl -fsSL https://raw.githubusercontent.com/MaksimovAV11/claude-corp-proxy/main/install.sh | bash
# Без вопросов:
#   ... | bash -s -- --proxy http://user:pass@host:port --name claude-proxy --port 10808 --yes
set -euo pipefail

REPO="${CCP_REPO:-MaksimovAV11/claude-corp-proxy}"
REF="${CCP_REF:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$REF"
CCP_HOME="$HOME/.local/share/claude-corp-proxy"
CONF_DIR="$HOME/.config/claude-corp-proxy"
CONF="$CONF_DIR/config"
BIN_DIR="$HOME/.local/bin"

PROXY=""; NAME=""; PORT=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --proxy) PROXY="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,6p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "неизвестный параметр: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; D=""; G=""; Y=""; R=""; C=""; N=""; fi
step() { printf '\n%s▸ %s%s\n' "$C$B" "$1" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
die()  { printf '  %s✗ %s%s\n' "$R" "$1" "$N" >&2; exit 1; }

# Вопросы читаем с терминала, даже когда скрипт пришёл через curl | bash.
TTY=/dev/tty
ask() {  # ask "вопрос" "по умолчанию" [secret]
  local q="$1" def="${2:-}" ans=""
  [ -r "$TTY" ] || { echo "$def"; return; }
  if [ -n "$def" ]; then printf '  %s %s[%s]%s: ' "$q" "$D" "$def" "$N" > "$TTY"; else printf '  %s: ' "$q" > "$TTY"; fi
  if [ "${3:-}" = secret ]; then IFS= read -rs ans < "$TTY"; echo > "$TTY"; else IFS= read -r ans < "$TTY"; fi
  echo "${ans:-$def}"
}

cat <<EOF

${B}  ┌──────────────────────────────────────────────┐
  │   Claude Corp Proxy                          │
  │   Claude Code через корпоративный прокси     │
  └──────────────────────────────────────────────┘${N}
EOF

step "Проверка системы"
command -v python3 >/dev/null || die "нужен python3 (3.8+)"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' || die "нужен python3 версии 3.8 или новее"
ok "python3 $(python3 -c 'import platform; print(platform.python_version())')"
if command -v claude >/dev/null || [ -x "$HOME/.local/bin/claude" ] || [ -x "$HOME/.claude/local/claude" ]; then
  ok "Claude Code найден"
else
  warn "Claude Code не найден. Поставьте его потом: ${B}curl -fsSL https://claude.ai/install.sh | bash${N}"
fi

step "Прокси"
if [ -z "$PROXY" ]; then
  printf '  %sФормат: http://логин:пароль@host:port или host:port без авторизации.%s\n' "$D" "$N" > "${TTY}" 2>/dev/null || true
  PROXY="$(ask "Строка HTTP-прокси" "" secret)"
fi
[ -n "$PROXY" ] || die "строка прокси не задана"
case "$PROXY" in http://*) ;; https://*|socks*) die "поддерживается только http:// прокси" ;; *://*) die "неизвестная схема прокси" ;; *) PROXY="http://$PROXY" ;; esac
printf '%s' "$PROXY" | grep -Eq '^http://([^@/]+@)?[^:/@]+:[0-9]{1,5}/?$' || die "не похоже на http://[логин:пароль@]host:port"
ok "прокси принят ($(printf '%s' "$PROXY" | sed -E 's#^http://([^:@/]+)(:[^@/]*)?@#http://\1:***@#'))"

step "Команда запуска"
if [ -z "$NAME" ]; then NAME="$(ask "Как назвать команду" "claude-proxy")"; fi
printf '%s' "$NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$' || die "имя команды: латиница, цифры, точка, дефис, подчёркивание"
[ "$NAME" = "claude" ] && die "имя claude занято самим Claude Code — выберите другое"
if command -v "$NAME" >/dev/null 2>&1 && [ "$(command -v "$NAME")" != "$BIN_DIR/$NAME" ]; then
  die "команда $NAME уже есть в системе ($(command -v "$NAME")) — выберите другое имя"
fi
ok "запуск: ${B}$NAME${N}"

if [ -z "$PORT" ]; then PORT="$(ask "Локальный порт моста" "10808")"; fi
printf '%s' "$PORT" | grep -Eq '^[0-9]{2,5}$' && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "порт должен быть 1024–65535"
if python3 - "$PORT" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
PY
then ok "порт $PORT свободен"
else
  [ -f "$CONF" ] && grep -q "^PORT=$PORT$" "$CONF" && ok "порт $PORT занят нашим мостом — переустановка" \
    || die "порт $PORT занят другой программой — укажите другой (--port)"
fi

if [ "$YES" -ne 1 ] && [ -r "$TTY" ]; then
  [ "$(ask "Установить? (y/n)" "y")" = "y" ] || die "отменено"
fi

step "Установка"
mkdir -p "$CCP_HOME" "$BIN_DIR"
install -d -m 700 "$CONF_DIR"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
fetch() {  # fetch файл назначение
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$1" ]; then cp "$SRC_DIR/$1" "$2"
  else curl -fsSL "$RAW/$1" -o "$2" || die "не удалось скачать $1"; fi
}
fetch bridge.py "$CCP_HOME/bridge.py"; chmod 755 "$CCP_HOME/bridge.py"
fetch launcher.sh "$CCP_HOME/launcher.sh"; chmod 755 "$CCP_HOME/launcher.sh"
fetch uninstall.sh "$CCP_HOME/uninstall.sh"; chmod 755 "$CCP_HOME/uninstall.sh"
ok "файлы в $CCP_HOME"

python3 "$CCP_HOME/bridge.py" --stop >/dev/null 2>&1 || true
umask 077
{
  echo "# Claude Corp Proxy — настройки. Файл доступен только вам (600)."
  echo "PROXY_URL=$PROXY"
  echo "PORT=$PORT"
  echo "COMMANDS=$( { sed -n 's/^COMMANDS=//p' "$CONF" 2>/dev/null; echo "$NAME"; } | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
} > "$CONF.new"
mv "$CONF.new" "$CONF"; chmod 600 "$CONF"
ok "настройки в $CONF (права 600)"

ln -sf "$CCP_HOME/launcher.sh" "$BIN_DIR/$NAME"
ok "команда $BIN_DIR/$NAME"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [ -f "$rc" ] || [ "$rc" = "$HOME/.bashrc" ] || continue
      grep -q 'claude-corp-proxy' "$rc" 2>/dev/null || printf '\n# claude-corp-proxy\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    done
    warn "добавил ~/.local/bin в PATH — откройте новый терминал или выполните: ${B}export PATH=\"\$HOME/.local/bin:\$PATH\"${N}"
    ;;
esac

step "Проверка прокси"
if python3 "$CCP_HOME/bridge.py" --check | sed 's/^/  /'; then
  python3 "$CCP_HOME/bridge.py" --ensure && ok "мост запущен на 127.0.0.1:$PORT"
else
  warn "прокси сейчас не пускает к api.anthropic.com — проверьте строку: ${B}$NAME --proxy-set http://…${N}"
fi

cat <<EOF

${G}${B}  Готово.${N}

  ${B}$NAME${N}                  запустить Claude Code через прокси
  ${B}$NAME -c${N}               продолжить последний разговор (любые флаги claude работают)
  ${B}$NAME --proxy-test${N}     проверить прокси
  ${B}$NAME --proxy-status${N}   состояние моста
  ${B}$NAME --proxy-set URL${N}  сменить прокси
  ${B}$NAME --proxy-help${N}     справка
  ${D}удалить: $CCP_HOME/uninstall.sh${N}

EOF
