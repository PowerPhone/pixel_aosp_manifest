// Print the processor/language identity and mapped memory blocks for an AoC image.
// @category PowerPhone

import ghidra.app.script.GhidraScript;
import ghidra.program.model.mem.MemoryBlock;

public class PrintProgramInfo extends GhidraScript {
    @Override
    public void run() throws Exception {
        println("name=" + currentProgram.getName());
        println("executable_path=" + currentProgram.getExecutablePath());
        println("executable_format=" + currentProgram.getExecutableFormat());
        println("language=" + currentProgram.getLanguageID());
        println("compiler_spec=" + currentProgram.getCompilerSpec().getCompilerSpecID());
        println("image_base=" + currentProgram.getImageBase());
        for (MemoryBlock block : currentProgram.getMemory().getBlocks()) {
            println("block " + block.getName() + " " + block.getStart() + ".." +
                block.getEnd() + " size=" + block.getSize() +
                " r=" + block.isRead() + " w=" + block.isWrite() +
                " x=" + block.isExecute());
        }
    }
}
