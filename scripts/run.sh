#!/bin/zsh
# Собирает и запускает локальный прототип ShotQueue.
# Запуск: ./scripts/run.sh из корня зоны ShotQueue.
set -eu
cd "${0:A:h}/.."
if pgrep -f '^/Applications/ShotQueue.app/Contents/MacOS/ShotQueue$' >/dev/null; then
  echo "Установленный ShotQueue уже запущен. Закрой его перед запуском сборки." >&2
  exit 1
fi
./scripts/build.sh
open .build/ShotQueue.app
