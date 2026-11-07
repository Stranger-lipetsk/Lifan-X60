package ru.lifanx60.storagelab;

/** Pure parser for /proc/mounts. Selecting p5 by this literal name is not exhaustive. */
public final class MountFilter {
    private MountFilter() { }

    public static String select(String line) {
        String[] fields = line.trim().split("\\s+");
        if (fields.length < 4) return null;
        if (!"/data".equals(fields[1]) && !"/dev/block/mmcblk0p5".equals(fields[0])) return null;
        // Display only fixed fields: no directory listings, account names or file contents.
        return fields[0] + " " + fields[1] + " " + fields[2] + " " + fields[3];
    }
}
