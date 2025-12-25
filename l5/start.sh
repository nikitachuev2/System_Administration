#!/usr/bin/env bash
set -euo pipefail

info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/ansible"

# 1. Проверяем наличие ansible
if ! command -v ansible-playbook >/dev/null 2>&1; then
  info "Ansible не найден, ставлю..."
  sudo apt update
  sudo apt install -y ansible python3-apt sshpass
else
  info "Ansible уже есть"
fi

CHECKS_DIR="$SCRIPT_DIR/ansible/checks"
if [ -d "$CHECKS_DIR" ] && ls "$CHECKS_DIR"/*.txt >/dev/null 2>&1; then
  CHECKS_PRESENT=1
else
  CHECKS_PRESENT=0
fi

# 2. Пытаемся понять, установлен ли ClickHouse хотя бы где-то
CLUSTER_DEPLOYED=0
if ansible -i inventories/lab/hosts.ini clickhouse \
     -m shell -a 'command -v clickhouse-server >/dev/null 2>&1 && echo INSTALLED || echo MISSING' \
     >/tmp/ansible-ch-detect.log 2>&1; then
  if grep -q "INSTALLED" /tmp/ansible-ch-detect.log; then
    CLUSTER_DEPLOYED=1
  fi
else
  warn "Ansible пока не может опросить хосты (возможно, bootstrap ещё не выполнялся)."
fi

MODE="${1:-auto}"

case "$MODE" in
  deploy)
    info "Режим: форсированный деплой (bootstrap + deploy + test)"
    make bootstrap
    make deploy
    make test
    ;;
  test)
    info "Режим: только тесты (кластер уже должен быть развёрнут)"
    make test
    ;;
  auto)
    if [ "$CLUSTER_DEPLOYED" -eq 1 ]; then
      info "Похоже, ClickHouse уже установлен хотя бы на части нод → прогоняем только тесты (make test)"
      make test
    else
      info "Кластер ещё не развёрнут → делаем bootstrap + deploy + test"
      make bootstrap
      make deploy
      make test
    fi
    ;;
  *)
    error "Неизвестный режим: $MODE. Используйте: deploy | test | auto"
    exit 1
    ;;
esac

info "Готово."
