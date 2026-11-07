package ru.lifanx60.storagelab;

/** Linux sysfs block-device size is a count of 512-byte sectors. */
public final class SectorParser {
    private SectorParser() { }
    public static long toBytes(String text) {
        if (text == null || !text.matches("[0-9]{1,19}")) throw new IllegalArgumentException("invalid sectors");
        long sectors = Long.parseLong(text);
        if (sectors > Long.MAX_VALUE / 512L) throw new IllegalArgumentException("capacity overflow");
        return sectors * 512L;
    }
}
