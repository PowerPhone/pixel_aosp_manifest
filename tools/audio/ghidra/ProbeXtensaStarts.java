// Probe every byte in a small raw Xtensa range as a possible instruction start.
// @category PowerPhone

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.mem.Memory;

public class ProbeXtensaStarts extends GhidraScript {
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
        for (Address cursor = start;
                cursor.compareTo(end) <= 0 && !monitor.isCancelled();
                cursor = cursor.add(1)) {
            Address clearEnd = cursor.add(15);
            if (clearEnd.compareTo(currentProgram.getMaxAddress()) > 0) {
                clearEnd = currentProgram.getMaxAddress();
            }
            clearListing(cursor, clearEnd);
            if (!disassemble(cursor)) {
                continue;
            }
            Instruction instruction = getInstructionAt(cursor);
            if (instruction != null) {
                println(String.format(
                    "%s len=%d %-32s %s",
                    cursor, instruction.getLength(), bytesAt(instruction), instruction));
            }
        }
    }
}
