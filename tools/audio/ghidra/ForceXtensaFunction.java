// Force disassembly of one known Xtensa entry point in a raw AoC image.
// @category PowerPhone

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class ForceXtensaFunction extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 2) {
            throw new IllegalArgumentException("ENTRY CLEAR_END required");
        }
        Address entry = toAddr(args[0]);
        Address clearEnd = toAddr(args[1]);
        clearListing(entry, clearEnd);
        println("disassemble " + entry + ": " + disassemble(entry));
        Function function = getFunctionAt(entry);
        if (function == null) {
            function = createFunction(entry, "aoc_function_" + entry);
        }
        println("function: " + function);
        analyzeChanges(currentProgram);
    }
}
