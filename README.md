# Claude Corp Proxy

![license](https://img.shields.io/badge/license-MIT-black) ![platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-black) ![deps](https://img.shields.io/badge/dependencies-python3%20only-black)

Запуск **Claude Code** через корпоративный HTTP-прокси одной командой.

```bash
curl -fsSL https://raw.githubusercontent.com/MaksimovAV11/claude-corp-proxy/main/install.sh | bash
claude-proxy
```

Claude Code умеет работать через прокси (`HTTPS_PROXY`), но прокси с логином и паролем
приходится прописывать в переменных окружения — пароль оказывается в истории шелла,
в `ps` и в окружении каждого дочернего процесса. Claude Corp Proxy поднимает маленький
локальный мост на `127.0.0.1`, который сам добавляет авторизацию к запросам. Пароль лежит
в одном файле с правами `600` и больше нигде не светится.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/MaksimovAV11/claude-corp-proxy/main/install.sh | bash
```

Установщик спросит:

1. **Строку HTTP-прокси** — `http://логин:пароль@host:port` или просто `host:port`.
   Ввод скрыт, строка сохраняется в `~/.config/claude-corp-proxy/config` с правами `600`.
2. **Имя команды** — по умолчанию `claude-proxy`. Можно любое: `cc`, `claude-work`, `ai`…
3. **Локальный порт моста** — по умолчанию `10808`.

После установки он сам проверит, что прокси пускает к `api.anthropic.com`.

Без вопросов (для скриптов и CI):

```bash
curl -fsSL https://raw.githubusercontent.com/MaksimovAV11/claude-corp-proxy/main/install.sh \
  | bash -s -- --proxy "http://user:pass@proxy.corp:3128" --name claude-proxy --port 10808 --yes
```

Нужны `bash`, `curl` и `python3` 3.8+. Сторонних зависимостей нет.
Сам Claude Code ставится отдельно: `curl -fsSL https://claude.ai/install.sh | bash`.

## Использование

```bash
claude-proxy                  # Claude Code через прокси
claude-proxy -c               # любые флаги claude работают как обычно
claude-proxy --resume

claude-proxy --proxy-test     # проверить, что прокси пускает к api.anthropic.com
claude-proxy --proxy-status   # запущен ли мост и куда он смотрит
claude-proxy --proxy-set URL  # сменить прокси
claude-proxy --proxy-stop     # остановить мост
claude-proxy --proxy-help     # справка
```

Мост стартует сам при первом запуске и живёт в фоне. Обычная команда `claude` при этом
продолжает работать напрямую — прокси включается только через вашу команду.

## Как это устроено

```
claude-proxy ──► Claude Code ──HTTPS_PROXY──► 127.0.0.1:10808 (мост) ──► корпоративный прокси ──► api.anthropic.com
                                               └ добавляет Proxy-Authorization
```

- `launcher.sh` — команда запуска: поднимает мост, выставляет `HTTPS_PROXY` / `HTTP_PROXY`
  на `127.0.0.1` и запускает `claude` со всеми вашими аргументами.
- `bridge.py` — мост: принимает соединения только с `127.0.0.1`, пробрасывает `CONNECT`
  и обычные HTTP-запросы на корпоративный прокси, подставляя авторизацию.
- Трафик к Anthropic остаётся зашифрованным TLS от начала до конца — мост его не видит.

Файлы:

| Что | Где |
|---|---|
| программа | `~/.local/share/claude-corp-proxy/` |
| настройки и прокси (`600`) | `~/.config/claude-corp-proxy/config` |
| лог моста | `~/.cache/claude-corp-proxy/bridge.log` |
| команда | `~/.local/bin/<имя>` |

## Удаление

```bash
~/.local/share/claude-corp-proxy/uninstall.sh
```

Удаляет команду, мост и сохранённый прокси. Claude Code не трогает.

## Ограничения

- Поддерживаются HTTP-прокси (`http://`) с Basic-авторизацией или без неё. SOCKS не поддерживается.
- Linux и macOS. На Windows — через WSL.

---

**English.** One-command launcher for Claude Code behind a corporate HTTP proxy. The installer
asks for the proxy URL and the command name, stores credentials in a `600` file and runs a tiny
loopback bridge that adds `Proxy-Authorization`, so the password never appears in env vars,
`ps` or shell history. `claude-proxy` starts Claude Code through it; `--proxy-test`,
`--proxy-status`, `--proxy-set`, `--proxy-stop` manage it.

## Лицензия

MIT
