// Enumerate every function in the program to a TSV for batch decompilation.
//
// Script arguments:
//   0  output file (default /tmp/functions.tsv)
//
// Columns: entry point, function name, addressable bytes in the body.

import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;

import java.io.FileWriter;
import java.io.PrintWriter;

public class ListFunctions extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String target = args.length > 0 ? args[0] : "/tmp/functions.tsv";

        int count = 0;
        PrintWriter out = new PrintWriter(new FileWriter(target));
        try {
            for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
                out.println(function.getEntryPoint() + "\t" + function.getName() + "\t"
                    + function.getBody().getNumAddresses());
                count++;
            }
        }
        finally {
            out.close();
        }
        println("LIST_FUNCTIONS_DONE " + count);
    }
}
