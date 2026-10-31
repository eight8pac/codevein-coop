// Print raw bytes from the program image. Args: <output file> name:0xSTART:0xLEN [...]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DumpBytes extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        PrintWriter out = new PrintWriter(new FileWriter(args[0]));
        for (int i = 1; i < args.length; i++) {
            String[] p = args[i].split(":");
            Address start = toAddr(p[1]);
            int len = Integer.decode(p[2]);
            byte[] b = getBytes(start, len);
            StringBuilder sb = new StringBuilder();
            for (byte x : b) sb.append(String.format("%02X ", x & 0xFF));
            out.println(p[0] + " " + start + ": " + sb.toString().trim());
        }
        out.close();
    }
}
