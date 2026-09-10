// Print references to an address and the containing functions.
// @category PowerPhone

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;

import java.util.LinkedHashSet;
import java.util.Set;

public class FindAddressXrefs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            throw new IllegalArgumentException("one address required");
        }
        Address target = toAddr(args[0]);
        Reference[] references = getReferencesTo(target);
        println("target " + target + " references=" + references.length);
        Set<Function> functions = new LinkedHashSet<>();
        for (Reference reference : references) {
            Function function = getFunctionContaining(reference.getFromAddress());
            println("  " + reference.getReferenceType() + " from " +
                reference.getFromAddress() + " function=" + function);
            if (function != null) {
                functions.add(function);
            }
        }
        for (Function function : functions) {
            println("function " + function.getName() + " " +
                function.getEntryPoint() + " body=" + function.getBody());
        }
    }
}
