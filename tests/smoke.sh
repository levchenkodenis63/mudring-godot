#!/bin/sh
# Быстрая проверка после правок: скрипты разбираются, ядро (tests/sim.gd) работает,
# заезды на автопилоте на всех уровнях доходят до конца (финиш или законный сход на Экстриме).
#   GODOT=godot tests/smoke.sh
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
# Godot при ошибке разбора скрипта не завершается сам — ограничиваем время (в macOS нет timeout)
run() { perl -e 'alarm 300; exec @ARGV' "$GODOT" --headless --path . "$@" 2>&1; }
fail=0
out=$(run -s tests/sim.gd)
echo "$out" | grep -E '^(good|bots) '
if echo "$out" | grep -q "SCRIPT ERROR" || ! echo "$out" | grep -q '^bots '; then echo "ОШИБКА: ядро не отработало"; fail=1; fi
for m in easy normal hard extreme:mudlite extreme:assassinator; do
  line=$(run -- --auto=$m --quit | grep -E "^AUTO|SCRIPT ERROR" | head -1)
  echo "$line"
  case "$line" in *": finish "*|*": break "*|*": drown "*|*": drive "*) ;; *) fail=1 ;; esac
done
if [ $fail = 0 ]; then echo "OK"; else echo "ПРОВАЛ"; exit 1; fi
