// Inspect known audio-function entries; use with analyzeHeadless -readOnly.
// This only changes the temporary analysis database, never the firmware bytes.
// @category PowerPhone

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class DecompileAudioEntries extends GhidraScript {
    @Override
    public void run() throws Exception {
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        try {
            for (String argument : getScriptArgs()) {
                Address entry = toAddr(argument);
                Function function = getFunctionAt(entry);
                if (function == null) {
                    println("disassemble " + entry + " = " + disassemble(entry));
                    function = createFunction(entry, "audio_" + entry);
                }
                println("entry " + entry + " function=" + function);
                if (function == null) continue;
                DecompileResults result = decompiler.decompileFunction(function, 45, monitor);
                if (result.decompileCompleted()) {
                    println(result.getDecompiledFunction().getC());
                } else {
                    println("decompile failed: " + result.getErrorMessage());
                }
            }
        } finally {
            decompiler.dispose();
        }
    }
}
