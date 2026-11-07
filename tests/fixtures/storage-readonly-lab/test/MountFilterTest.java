import ru.lifanx60.storagelab.MountFilter;

public class MountFilterTest {
    private static void same(String expected, String actual) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError("expected=" + expected + " actual=" + actual);
        }
    }
    public static void main(String[] args) {
        same("tmpfs /data tmpfs rw,seclabel", MountFilter.select("tmpfs /data tmpfs rw,seclabel 0 0"));
        same("/dev/block/mmcblk0p5 /mnt/staging ext4 rw", MountFilter.select("/dev/block/mmcblk0p5 /mnt/staging ext4 rw 0 0"));
        same(null, MountFilter.select("/dev/block/mmcblk0p50 /mnt/staging ext4 rw 0 0"));
        same(null, MountFilter.select("/dev/block/a /data/user ext4 rw 0 0"));
        same(null, MountFilter.select("/dev/block/mmcblk0p5 /mnt/staging ext4"));
        same("/dev/block/mmcblk0p5 /mnt/a\\040b ext4 rw", MountFilter.select("/dev/block/mmcblk0p5 /mnt/a\\040b ext4 rw 0 0"));
        same(null, MountFilter.select(""));
        System.out.println("MountFilter tests passed");
    }
}
