// Dump all analyzed references to an address and decompile their functions.
// @category PowerPhone

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;

import java.util.HashSet;
import java.util.Set;

public class DumpReferencesTo extends GhidraScript {
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
        if (args.length != 1) {
            throw new IllegalArgumentException("ADDRESS required");
        }
        Address target = toAddr(args[0]);
        println("program range " + currentProgram.getMinAddress() + ".." +
            currentProgram.getMaxAddress());
        println("references to " + target);
        if (currentProgram.getMemory().contains(target)) {
            byte[] preview = new byte[64];
            int read = currentProgram.getMemory().getBytes(target, preview);
            StringBuilder hex = new StringBuilder();
            StringBuilder ascii = new StringBuilder();
            for (int index = 0; index < read; index++) {
                int value = preview[index] & 0xff;
                hex.append(String.format("%02x", value));
                ascii.append(value >= 0x20 && value < 0x7f ? (char) value : '.');
            }
            println("target bytes=" + hex + " ascii=" + ascii);
        } else {
            println("target is outside mapped memory");
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        Set<Address> decompiled = new HashSet<>();
        ReferenceIterator references = currentProgram.getReferenceManager()
            .getReferencesTo(target);
        int count = 0;
        while (references.hasNext() && !monitor.isCancelled()) {
            Reference reference = references.next();
            count++;
            Address from = reference.getFromAddress();
            Instruction instruction = getInstructionAt(from);
            if (instruction == null) {
                instruction = getInstructionContaining(from);
            }
            println("ref " + reference.getReferenceType() + " from " + from +
                (instruction == null ? "" :
                    " bytes=" + bytesAt(instruction) + " instruction=" + instruction));

            Function function = currentProgram.getFunctionManager()
                .getFunctionContaining(from);
            if (function == null || !decompiled.add(function.getEntryPoint())) {
                continue;
            }
            println("function " + function.getName() + " " +
                function.getEntryPoint() + " body=" + function.getBody());
            DecompileResults result = decompiler.decompileFunction(
                function, 120, monitor);
            if (result.decompileCompleted()) {
                println("decompile:\n" + result.getDecompiledFunction().getC());
            } else {
                println("decompile failed: " + result.getErrorMessage());
            }
        }
        println("reference_count=" + count);
        decompiler.dispose();
    }
}
