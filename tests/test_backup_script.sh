#!/usr/bin/env bash
# Проверка логики tools/backup-device.sh без устройства.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=tools/backup-device.sh
FAIL=0

ok(){ echo "  [ok] $1"; }
bad(){ echo "  [!!] $1"; FAIL=1; }

sh -n "$SRC" 2>/dev/null && ok "синтаксис sh" || bad "синтаксис sh"
bash -n "$SRC" 2>/dev/null && ok "синтаксис bash" || bad "синтаксис bash"

OUT_H=$(sh "$SRC" --help 2>&1)
case "$OUT_H" in *"использование"*) ok "ключ --help";; *) bad "ключ --help";; esac

grep -q 'WITH_NAVI=1' "$SRC" && ok "есть --with-navi" || bad "нет --with-navi"
grep -q 'SMALL=1'     "$SRC" && ok "есть --small"     || bad "нет --small"

grep -q 'if \[ "\$SMALL" = "0" \]; then' "$SRC" && ok "--small пропускает p2/p3/p5" || bad "--small не пропускает p2/p3/p5"
grep -q 'if \[ "\$WITH_NAVI" = "1" \]; then' "$SRC" && ok "p7 только с --with-navi" || bad "p7 не под флагом"

grep -q 'id -u' "$SRC" && ok "проверка root" || bad "нет проверки root"
grep -q '/storage/extsd/lifan-backup' "$SRC" && ok "проверка SD" || bad "нет проверки SD"
grep -q 'NEED_MB' "$SRC" && ok "проверка места" || bad "нет проверки места"
grep -q 'sha256sum' "$SRC" && ok "контрольные суммы" || bad "нет контрольных сумм"

grep -q 'p\$P-\$DESC.img' "$SRC" && ok "p6: образ" || bad "p6: нет образа"
grep -q 'para_fw' "$SRC" && ok "p6: файлы" || bad "p6: нет файлов"

grep -q "NEED_MB=1800" "$SRC" && ok "лимит места (обычный)" || bad "лимит места (обычный)"
grep -q "NEED_MB=450"  "$SRC" && ok "лимит места (--small)" || bad "лимит места (--small)"
grep -q "NEED_MB=3700" "$SRC" && ok "лимит места (--with-navi)" || bad "лимит места (--with-navi)"

# имитация: нет root -> выход с ошибкой
FAKE=$(mktemp -d)
mkdir -p "$FAKE/bin"
printf '#!/bin/sh\necho 2000\n' > "$FAKE/bin/id"
chmod +x "$FAKE/bin/id"
R=$(PATH="$FAKE/bin:$PATH" sh "$SRC" 2>&1; echo "код=$?")
case "$R" in *"нужны права root"*) ok "без root отказывается";; *) bad "без root не отказывается";; esac
case "$R" in *"код=1") ok "код возврата 1";; *) bad "код возврата не 1";; esac
rm -rf "$FAKE"

echo
[ "$FAIL" = "0" ] && echo "ИТОГ: все проверки пройдены" || echo "ИТОГ: есть ошибки"
exit "$FAIL"
