// Decompile the function that contains each given address (any address inside it).
// Args: <output file> 0xADDR [0xADDR ...]
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class FuncAt extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        PrintWriter out = new PrintWriter(new FileWriter(args[0]));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        for (int i = 1; i < args.length; i++) {
            Address a = toAddr(args[i]);
            Function f = getFunctionContaining(a);
            if (f == null) {
                disassemble(a);
                createFunction(a, null);
                f = getFunctionContaining(a);
            }
            out.println("==== " + args[i] + " in " + (f == null ? "(no function)" : f.getName() + " @ " + f.getEntryPoint() + " size " + f.getBody().getNumAddresses()));
            if (f != null) {
                DecompileResults r = decomp.decompileFunction(f, 60, monitor);
                if (r.decompileCompleted()) out.println(r.getDecompiledFunction().getC());
                else out.println("(decompile failed: " + r.getErrorMessage() + ")");
            }
            out.flush();
        }
        out.close();
    }
}
