// Dump an analyzed Xtensa range, references, and any containing function.
// @category PowerPhone

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.Reference;

public class DumpXtensaRange extends GhidraScript {
    private String bytesAt(Instruction instruction) throws Exception {
        Memory memory = currentProgram.getMemory();
        byte[] bytes = new byte[instruction.getLength()];
        memory.getBytes(instruction.getAddress(), bytes);
        StringBuilder result = new StringBuilder();
        for (byte value : bytes) {
            result.append(String.format("%02x", value & 0xff));
        }
        return result.toString();
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 2) {
            throw new IllegalArgumentException("START END required");
        }
        Address start = toAddr(args[0]);
        Address end = toAddr(args[1]);
        println("range " + start + ".." + end);

        InstructionIterator instructions = currentProgram.getListing().getInstructions(
            new AddressSet(start, end), true);
        while (instructions.hasNext() && !monitor.isCancelled()) {
            Instruction instruction = instructions.next();
            println(String.format(
                "%s  %-24s  %s",
                instruction.getAddress(), bytesAt(instruction), instruction));
            for (Reference ref : instruction.getReferencesFrom()) {
                println("    ref " + ref.getReferenceType() + " -> " + ref.getToAddress());
            }
        }

        Function function = currentProgram.getFunctionManager().getFunctionContaining(start);
        if (function == null) {
            function = currentProgram.getFunctionManager().getFunctionContaining(end);
        }
        if (function == null) {
            println("no containing function");
            return;
        }
        println("function " + function.getName() + " " + function.getEntryPoint() +
            " body=" + function.getBody());

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
        if (result.decompileCompleted()) {
            println("decompile:\n" + result.getDecompiledFunction().getC());
        } else {
            println("decompile failed: " + result.getErrorMessage());
        }
        decompiler.dispose();
    }
}
