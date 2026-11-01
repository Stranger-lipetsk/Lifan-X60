#!/usr/bin/env bash
# Автоанализ прошивки Lifan X60 FL
set -e
FILE="${1:-}"
if [ -z "$FILE" ]; then
  echo "Использование: $0 firmware/original/файл.img"
  echo "Найдено в firmware/original/:"
  ls -lh firmware/original/ 2>/dev/null || echo "  (папка пуста)"
  exit 1
fi
if [ ! -f "$FILE" ]; then
  echo "Файл не найден: $FILE"
  exit 1
fi

OUT_DIR="docs/отчеты"
mkdir -p "$OUT_DIR"
BASENAME=$(basename "$FILE")
REPORT="$OUT_DIR/анализ-$BASENAME.txt"

echo "=== Анализ прошивки: $FILE ===" | tee "$REPORT"
echo "Дата: $(date)" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "--- 1. Базовая информация ---" | tee -a "$REPORT"
ls -lh "$FILE" | tee -a "$REPORT"
echo "SHA256: $(sha256sum "$FILE" | cut -d' ' -f1)" | tee -a "$REPORT"
echo "Тип файла:" | tee -a "$REPORT"
file "$FILE" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "--- 2. Строковые маркеры (SoC, Android, сборка) ---" | tee -a "$REPORT"
strings "$FILE" | grep -i -E "android|rk30|rk31|rk32|rk33|px3|px5|px6|allwinner|sunxi|mtk|mediatek|msm|board|build\.prop|kernel|linux version" | head -n 100 | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "--- 3. Заголовок (первые 2KB hex) ---" | tee -a "$REPORT"
hexdump -C -n 2048 "$FILE" | head -n 30 | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "--- 4. Binwalk (структура образов) ---" | tee -a "$REPORT"
if command -v binwalk >/dev/null 2>&1; then
  binwalk "$FILE" | tee -a "$REPORT"
else
  echo "binwalk не установлен, пропускаем" | tee -a "$REPORT"
fi
echo "" | tee -a "$REPORT"

echo "--- 5. Попытка unzip -l (если это zip) ---" | tee -a "$REPORT"
unzip -l "$FILE" 2>&1 | head -n 100 | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "--- 6. 7z l (универсальный листинг) ---" | tee -a "$REPORT"
if command -v 7z >/dev/null 2>&1; then
  7z l "$FILE" 2>&1 | head -n 150 | tee -a "$REPORT"
else
  echo "7z не установлен" | tee -a "$REPORT"
fi
echo "" | tee -a "$REPORT"

echo "=== Готово. Отчёт сохранён: $REPORT ==="
echo "Следующий шаг: распаковать разделы и изучить build.prop / dtb"
