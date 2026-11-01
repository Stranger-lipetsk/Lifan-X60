# Кнопка MirrorLink = выход к Android

## Что выяснено

На главном экране магнитолы есть кнопка **MirrorLink**, но она не работает.
Причина найдена по образу и по коду оболочки:

| Факт | Подтверждение |
|---|---|
| Кнопка завязана на пакет `com.fpt.mirrorlink.android` | в `EL830LF01_Home.apk`: константа `PACKAGE_MIRRORLINK`, класс `MirrorLinkReceiver`, строка `com.fpt.mirrorlink.android`, ресурсы `main_btn_mirrorlink_normal/disable`, метод `enableMirrorLinkIcon` |
| Этого пакета **нет в прошивке** | полный список 70 установленных пакетов — `com.fpt.mirrorlink.android` отсутствует, файла `*MirrorLink*.apk` нет |
| Поэтому кнопка ничего не открывает | оболочка ловит состояние через `MSG_UPDATE_MIRRORLINK_STATE` и гасит иконку (`bEnanble = false`) |

То есть **пакет просто не положили в образ** — Elead собирал прошивки с MirrorLink
и без него. Раз оболочка всё равно ищет `com.fpt.mirrorlink.android`, мы можем
сделать под этим именем что угодно. Это самая удобная точка входа: кнопка уже
есть на экране, и оболочка её обрабатывает.

## Решение

Приложение **«Переключатель»** теперь ставится как **`com.fpt.mirrorlink.android`**.
Кнопка MirrorLink включает именно его.

### Что открывается

| Кнопка | Куда ведёт |
|---|---|
| **Магнитола (штатная оболочка)** | `tw.com.elead.el830.home` |
| **Стандартный Android (рабочий стол)** | `com.android.launcher` — обычный рабочий стол со списком всех приложений |
| **Настройки Android** | `android.settings.SETTINGS` (это `ElSettings.apk` — полный `com.android.settings`) |
| **Настройки Wi-Fi** | `android.settings.WIFI_SETTINGS` |
| **Приложения: установка и удаление** | `MANAGE_APPLICATIONS_SETTINGS` |
| **Файловый менеджер** | `DocumentsUI` |
| **Память и USB-накопители** | `INTERNAL_STORAGE_SETTINGS` |
| **Для разработчиков (ADB)** | `APPLICATION_DEVELOPMENT_SETTINGS` |

Приложение ищет обработчики через `PackageManager` по реальным активностям,
поэтому не зависит от жёстко прописанных имён.

### Дополнительно: HOME-режим (по желанию)

В приложении есть выключенный компонент `.HomeAlias`. Если включить его,
кнопка «Домой» тоже будет открывать панель:

```bash
adb shell pm enable com.fpt.mirrorlink.android/.HomeAlias
# вернуть как было:
adb shell pm disable com.fpt.mirrorlink.android/.HomeAlias
```

По умолчанию **выключен** — кнопка «Домой» работает штатно.

## Как включить кнопку MirrorLink

### Вариант 1: только установить APK (без перепрошивки)

```bash
adb install -r com.fpt.mirrorlink.android.apk
```

Готовый APK — артефакт `switcher-mirrorlink-apk` в запуске
[«Сборка APK «Переключатель»»](https://github.com/Stranger-lipetsk/Lifan-X60/actions/workflows/build-switcher.yml).

APK уже в образе, так что этот шаг нужен только если не перепрошиваешь.

### Вариант 2: перепрошить образ (уже готов)

Панель лежит в образе как `/app/com.fpt.mirrorlink.android.apk`:

**https://github.com/Stranger-lipetsk/Lifan-X60/actions/runs/41317590215**

| Параметр | Значение |
|---|---|
| Размер | 536 870 912 байт = 512 МиБ |
| Свободно | 273 МиБ (`Free blocks 70028`) |
| sha256 | `b333fa8a4e9c8ad941b3b8bfec71240b9b460fdddc96b7fe9e1688f54d86f651` |
| `/app/com.fpt.mirrorlink.android.apk` | 16 879 байт, 0644, root:root |
| `/etc/install-recovery.sh` | 6265 байт, 0755 |
| Клавиатура IQQI | на месте |

## Что если кнопка всё равно не открывает панель

Оболочка может запускать не просто `getLaunchIntentForPackage`, а конкретную
активность или сервис. Тогда есть три запасных пути — по возрастанию сложности:

1. **Проверить, видит ли оболочка пакет.**
   ```bash
   adb shell pm list packages | grep fpt
   adb shell am start -n com.fpt.mirrorlink.android/.MainActivity
   ```
   Если команда `am start` открывает панель, а кнопка нет — дело в том,
   *как* оболочка запускает.

2. **Создать недостающий сервис/ресивер.** Оболочка содержит
   `MirrorLinkReceiver` и `MSG_UPDATE_MIRRORLINK_STATE`. Если она ждёт
   широковещательное сообщение о состоянии — добавим в манифест приёмник
   с нужным action (потребуется ещё один прогон разбора: посмотреть, какой
   action регистрируется в `MirrorLinkReceiver`).

3. **Перекрыть кнопку на уровне оболочки.** Оболочка читает состояние
   MirrorLink из системного свойства / настроек. Можно подставить значение
   «включено» — тогда иконка станет активной. Требует правки
   `SettingsProvider` или `build.prop`, делается в образе.

Точный ответ даст проверка пункта 1 на машине: `am start` покажет, работает
ли пакет сам по себе, а лог `logcat` при нажатии кнопки покажет, что именно
вызывает оболочка.

## Сборка APK из исходников

```bash
bash switcher/build.sh          # нужен Android SDK + JDK 8+
# результат: switcher/switcher.apk (пакет com.fpt.mirrorlink.android)
```

### Состав

```
switcher/
  AndroidManifest.xml                      пакет com.fpt.mirrorlink.android
    .MainActivity                          панель (LAUNCHER)
    .HomeAlias                             HOME-режим, выключен по умолчанию
    com.fpt.mirrorlink.android.MirrorLinkActivity   алиас на MainActivity
  src/com/fpt/mirrorlink/android/MainActivity.java
  res/drawable/ic_launcher.png
  build.sh                                 сборка без Gradle (aapt/d8/apksigner)
```

## Если нужно откатить

```bash
adb uninstall com.fpt.mirrorlink.android
```

Или из образа удалить `/app/com.fpt.mirrorlink.android.apk` (правкой
`tools/build_lite.sh` — убрать строку с `--add-apk`). Кнопка MirrorLink снова
станет неактивной, как в заводской прошивке. Ничего другого не затронуто.
