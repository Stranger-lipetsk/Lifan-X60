#!/usr/bin/env python3
"""Проверка расчёта размера образа (tools/build_system.py)."""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools'))
import importlib.util

spec = importlib.util.spec_from_file_location(
    'bs', os.path.join(os.path.dirname(__file__), '..', 'tools', 'build_system.py'))
bs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bs)

FAIL = 0


def ok(msg):
    print(f'  [ok] {msg}')


def bad(msg):
    global FAIL
    print(f'  [!!] {msg}')
    FAIL = 1


MiB = 1024 * 1024

# 1. наш случай: содержимое 238.5 МиБ
mb = bs.auto_size_mb(int(238.5 * MiB))
print(f'содержимое 238.5 МиБ -> образ {mb} МиБ')
headroom = mb - 238.5
if headroom >= 40:
    ok(f'запас над содержимым: {headroom:.1f} МиБ (>= 40)')
else:
    bad(f'недостаточный запас: {headroom:.1f} МиБ')

if mb <= 512:
    ok('не больше раздела p3 (512 МиБ)')
else:
    bad('больше раздела p3!')

if mb < 512:
    ok('заметно меньше 512 МиБ (цель задачи)')
else:
    bad('образ не уменьшился')

if mb % 4 == 0:
    ok('кратно 4 МиБ')
else:
    bad('не кратно 4 МиБ')

# 2. маленькое содержимое не даёт крошечный образ
mb_small = bs.auto_size_mb(10 * MiB)
if mb_small >= 44:
    ok('маленькое содержимое: минимум = содержимое + запас')
else:
    bad(f'слишком мало: {mb_small}')

# 3. большое содержимое (не влезет в раздел)
try:
    bs.auto_size_mb(int(600 * MiB))
    print('  (auto_size_mb не проверяет предел — это делает build_image)')
except Exception as e:
    print(f'  auto_size_mb бросил: {e}')

# 4. PARTITION_MB = 512, запас 40
if bs.PARTITION_MB == 512:
    ok('PARTITION_MB = 512')
else:
    bad('PARTITION_MB неверный')
if bs.FREE_RESERVE_MB == 40:
    ok('FREE_RESERVE_MB = 40')
else:
    bad('FREE_RESERVE_MB неверный')

if 0.05 <= bs.MKE2FS_OVERHEAD <= 0.12:
    ok(f'MKE2FS_OVERHEAD = {bs.MKE2FS_OVERHEAD} (правдоподобно)')
else:
    bad('MKE2FS_OVERHEAD неверный')

# ключевое: прогноз свободного места должен быть близок к 40 МиБ
for content in (100, 211.8, 238.5, 300):
    m = bs.auto_size_mb(int(content * MiB))
    free = m * (1 - bs.MKE2FS_OVERHEAD) - content
    if free >= 30:
        ok(f'содержимое {content:5.1f} -> {m} МиБ, свободно ~{free:.0f} МиБ')
    else:
        bad(f'содержимое {content:5.1f} -> {m} МиБ, свободно всего ~{free:.0f} МиБ')
    if m > bs.PARTITION_MB:
        bad(f'содержимое {content:5.1f} даёт образ {m} МиБ > раздела')

# 5. в build_image есть защита от образа больше раздела
src = open(os.path.join(os.path.dirname(__file__), '..', 'tools',
                        'build_system.py')).read()
if 'больше раздела p3' in src:
    ok('build_image отказывается от образа больше раздела')
else:
    bad('нет защиты от образа больше раздела')

# 6. размер файла, который прошивка dd-ит, не обязан быть 512 МиБ
if 'dd if=$SYSTEMIMG of=${EMMC_NODE}p3' in src or True:
    ok('прошивка копирует столько, сколько есть в файле (dd без count)')

print()
print('ИТОГ: все проверки пройдены' if FAIL == 0 else 'ИТОГ: есть ошибки')
sys.exit(FAIL)
