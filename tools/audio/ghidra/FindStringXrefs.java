// Find an ASCII string, print its references, and decompile referring functions.
// @category PowerPhone

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.Reference;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashSet;
import java.util.Set;

public class FindStringXrefs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            throw new IllegalArgumentException("one ASCII search string required");
        }

        byte[] needle = args[0].getBytes(StandardCharsets.US_ASCII);
        Memory memory = currentProgram.getMemory();
        Address cursor = memory.getMinAddress();
        Set<Function> functions = new LinkedHashSet<>();
        while (cursor != null && !monitor.isCancelled()) {
            Address hit = memory.findBytes(cursor, needle, null, true, monitor);
            if (hit == null) {
                break;
            }
            println("string " + hit + " = " + args[0]);
            Reference[] refs = getReferencesTo(hit);
            println("references=" + refs.length);
            for (Reference ref : refs) {
                println("  " + ref.getReferenceType() + " from " + ref.getFromAddress());
                Function function = getFunctionContaining(ref.getFromAddress());
                if (function != null) {
                    functions.add(function);
                }
            }
            cursor = hit.add(1);
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        for (Function function : functions) {
            println("function " + function.getName() + " " + function.getEntryPoint() +
                " body=" + function.getBody());
            DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
            if (result.decompileCompleted()) {
                println("decompile:\n" + result.getDecompiledFunction().getC());
            } else {
                println("decompile failed: " + result.getErrorMessage());
            }
        }
        decompiler.dispose();
    }
}
