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
| Размер | 289 406 976 байт = 276 МиБ |
| Свободно | 273 МиБ (`Free blocks 70028`) |
| sha256 | `d5c554d9855fd5fd1b525a0cf1bb74fdb4a9893ac69653a3b68254f2316e98a1` |
| `/app/com.fpt.mirrorlink.android.apk` | 16 879 байт, 0644, root:root |
| `/etc/install-recovery.sh` | 6265 байт, 0755 |
| Клавиатура IQQI | на месте |

## Почему кнопка была серой (разобрано 02.11.2026)

Первая версия панели встала в образ, но кнопка MirrorLink осталась **серой и
не нажималась**. Причина найдена в коде самой оболочки (`EL830LF01_Home.apk`,
разбор через baksmali — `probes/home2-condition.txt`, `probes/home3-*.txt`).

**Что делает оболочка.** При старте `HomeApp.loadEleadApplications()` собирает
таблицу своих приложений. Для пакета `com.fpt.mirrorlink.android` она явно
ставит `ApplicationInfo.enable = false`:

```
:cond_4df
const-string v9, "com.fpt.mirrorlink.android"
invoke-virtual {v7, v9}, Ljava/lang/String;->equalsIgnoreCase(Ljava/lang/String;)Z
...
.line 885
const/4 v9, 0x0
iput-boolean v9, v0, Ltw/com/elead/el830/home/ApplicationInfo;->enable:Z
```

То есть **иконка выключена по умолчанию всегда** — независимо от того, что
пакет установлен и что в нём есть `LAUNCHER`-активность.

**Что её включает.** `HomeService` регистрирует приёмник на три сообщения:

```
mirrorlinkfilter.addAction("vn.com.fsoft.UsbIfaceReady");   -> enableMirrorLinkIcon(true)
mirrorlinkfilter.addAction("vn.com.fsoft.UsbIfaceDown");    -> enableMirrorLinkIcon(false)
mirrorlinkfilter.addAction("vn.com.fsoft.getscreenoff");    -> гашение экрана
```

По первому сообщению вызывается `enableMirrorLinkIcon(true)` →
`enableEleadApplication("com.fpt.mirrorlink.android", true)` → иконка становится
активной и нажимаемой. Отправляло это сообщение **само оригинальное
приложение MirrorLink**, которого в прошивке нет.

**Вывод:** мало положить пакет в образ — нужно, чтобы кто-то отправил
`vn.com.fsoft.UsbIfaceReady` уже после старта оболочки.

## Что сделано

| Где | Что |
|---|---|
| `switcher/.../MainActivity.java` | при старте и при возврате на экран отправляет `vn.com.fsoft.UsbIfaceReady` |
| `tools/system-files/install-recovery.sh` | при загрузке ждёт процесс оболочки, затем шлёт сигнал 10 раз с интервалом 6 с |

Скрипт нужен потому, что нажать серую кнопку нельзя и запустить панель вручную
тоже — сигнал обязан прийти сам при загрузке. Скрипт выполняется от root на
каждой загрузке (`service flash_recovery /system/etc/install-recovery.sh`).

## Как проверить после прошивки

1. Кнопка MirrorLink на главном экране должна быть **цветной**, нажатие
   открывает панель.
2. Если осталась серой — посмотреть лог:
   ```bash
   adb shell cat /data/local/tmp/mount_storage.log
   ```
   Ищем строки:
   - `оболочка запущена (жду N циклов)` — скрипт дождался оболочки;
   - `сигнал MirrorLink отправлен: 10 из 10` — сигнал ушёл.

   Если строк нет вовсе — скрипт не запускался. Если `0 из 10` — в системе нет
   `/system/bin/am`.

3. Ручная проверка сигнала (пока панель хоть как-то доступна):
   ```bash
   adb shell am broadcast -a vn.com.fsoft.UsbIfaceReady
   ```
   После этого кнопка должна стать активной сразу.

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
