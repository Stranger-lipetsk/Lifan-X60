#!/usr/bin/env python3
"""Собирает макет главного экрана магнитолы из настоящих ресурсов оболочки.

Все картинки — из EL830LF01_Home.apk (фон, цифры часов, иконки кнопок),
поэтому макет показывает реальные элементы, а не рисованные.
Координаты взяты из res/layout/home.xml и res/values/dimens.xml.
"""
import os
from PIL import Image, ImageDraw, ImageFont

M = 'docs/mockup'
P = M + '/parts'
B = M + '/btns'
W, H = 800, 480

FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
FONT_B = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'


def font(size, bold=False):
    return ImageFont.truetype(FONT_B if bold else FONT, size)


def load(path, size=None):
    im = Image.open(path).convert('RGBA')
    if size:
        im = im.resize(size, Image.LANCZOS)
    return im


def main():
    img = Image.open(P + '/window_bg_full.png').convert('RGBA')
    if img.size != (W, H):
        img = img.resize((W, H), Image.LANCZOS)
    d = ImageDraw.Draw(img)

    # ---------- часы: настоящие светящиеся цифры из оболочки ----------
    digits = [load(P + '/main_ico_clock_%d.png' % i) for i in range(10)]
    colon = load(P + '/main_ico_clock_colon.png')
    hh, mm = '19', '24'
    parts = [digits[int(hh[0])], digits[int(hh[1])], colon,
             digits[int(mm[0])], digits[int(mm[1])]]
    gaps = [0, 3, 17, 17, 3]
    total = sum(p.width for p in parts) + sum(gaps)
    x = (W - total) // 2
    y = 38
    for p, g in zip(parts, gaps):
        x += g
        img.alpha_composite(p, (x, y))
        x += p.width

    # ---------- дата ----------
    d.text((W // 2, y + 70 + 14), 'вс, 2 ноября', font=font(24),
           fill=(255, 255, 255, 235), anchor='ma')

    # ---------- разделительная панель ----------
    bar = load(P + '/mainmenu_bg.png')
    img.alpha_composite(bar, ((W - bar.width) // 2, 162))

    # ---------- четыре избранных ----------
    fav_y = 214
    favs = [('Радио', 'main_btn_radio_normal.png'),
            ('Навигация', 'main_btn_navi_normal.png'),
            ('Музыка', 'main_btn_sd_normal.png'),
            ('Настройки', 'main_btn_setup_normal.png')]
    # четыре избранных в свободной части экрана, левее панели приложений
    left_w = 605
    step = 145
    start = left_w // 2 - (len(favs) - 1) * step // 2
    for i, (name, icon) in enumerate(favs):
        cx = start + i * step
        ic = load(B + '/drawable-mdpi-v4__' + icon, (96, 96))
        img.alpha_composite(ic, (cx - 48, fav_y))
        d.text((cx, fav_y + 108), name, font=font(20),
               fill=(255, 255, 255, 235), anchor='ma')

    # ---------- правая панель: полный список приложений ----------
    panel = load(P + '/main_bg_circle_list.png')
    # панель прижата к правому краю: 800 - ширина
    px, py = W - panel.width, 0
    img.alpha_composite(panel, (px, py))

    apps = [('Радио', 'main_btn_radio_normal.png'),
            ('BT телефон', 'main_btn_bt_phone_normal.png'),
            ('Музыка SD', 'main_btn_sd_normal.png'),
            ('Музыка USB', 'main_btn_usb_normal.png'),
            ('BT музыка', 'main_btn_bt_music_normal.png'),
            ('MirrorLink', 'main_btn_mirrorlink_normal.png'),
            ('AV-IN', 'main_btn_aux_normal.png'),
            ('Навител', 'main_btn_navi_normal.png'),
            ('Torque', None)]
    top = 10
    rowh = 50
    for name, icon in apps:
        if icon:
            ic = load(B + '/drawable-mdpi-v4__' + icon, (34, 34))
        else:
            ic = load(B + '/torque_icon.png', (34, 34))
        img.alpha_composite(ic, (px + 18, top))
        # подписи новых кнопок выделяем цветом
        new = name in ('Навител', 'Torque')
        col = (160, 255, 120, 255) if new else (235, 235, 235, 240)
        d.text((px + 58, top + 17), name, font=font(14, bold=new),
               fill=col, anchor='lm')
        top += rowh

    img.convert('RGB').save(M + '/главный-экран-макет.png')
    print('готово:', M + '/главный-экран-макет.png', img.size)


if __name__ == '__main__':
    main()
