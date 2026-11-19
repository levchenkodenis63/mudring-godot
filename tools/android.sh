#!/bin/sh
# Сборка отладочного APK и установка на телефон по USB.
#   tools/android.sh          — собрать build/mudring3d.apk
#   tools/android.sh install  — собрать, поставить на подключённый телефон и запустить
# Нужно: Godot 4.7, шаблоны экспорта 4.7.2, Android SDK (пути — в настройках редактора Godot:
# export/android/android_sdk_path и java_sdk_path), включённая «Отладка по USB» на телефоне.
set -e
cd "$(dirname "$0")/.."
SDK=${ANDROID_HOME:-/usr/local/share/android-commandlinetools}
ADB="$SDK/platform-tools/adb"
mkdir -p build
godot --headless --path . --export-debug "Android" build/mudring3d.apk 2>&1 | grep -E "ERROR|Signed|error" || true
ls -lh build/mudring3d.apk
if [ "$1" = "install" ]; then
  "$ADB" start-server >/dev/null 2>&1
  if "$ADB" devices | grep -q "unauthorized"; then
    echo "Телефон подключён, но не разрешил отладку: на его экране нажми «Разрешить» (можно отметить «Всегда»)."
    echo "Окна нет — переподключи кабель или «Для разработчиков → Отозвать доступ к отладке по USB»."
    exit 1
  fi
  if ! "$ADB" get-state >/dev/null 2>&1; then
    echo "Телефон не найден: подключи кабелем, включи «Отладку по USB» и разреши доступ этому компьютеру."
    "$ADB" devices -l
    exit 1
  fi
  "$ADB" install -r build/mudring3d.apk
  "$ADB" shell monkey -p com.mudring.ring3d -c android.intent.category.LAUNCHER 1 >/dev/null
  echo "Запущено. Лог игры: $ADB logcat -s godot"
fi
