import ru.lifanx60.storagelab.SectorParser;
public class SectorParserTest {
    private static void bad(String s) {
        try { SectorParser.toBytes(s); throw new AssertionError("accepted " + s); }
        catch (IllegalArgumentException expected) { }
    }
    public static void main(String[] args) {
        if (SectorParser.toBytes("2") != 1024 || SectorParser.toBytes("0") != 0) throw new AssertionError();
        if (SectorParser.toBytes("18014398509481983") != 9223372036854775296L) throw new AssertionError();
        bad(null); bad(""); bad("-1"); bad("1k"); bad("12 34"); bad("18014398509481984"); bad("99999999999999999999");
        System.out.println("SectorParser tests passed");
    }
}
