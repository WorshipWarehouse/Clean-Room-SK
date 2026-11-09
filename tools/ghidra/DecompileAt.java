// Decompile every function containing an address from a list.
//
// Script arguments:
//   0  input file, one hex address per line
//   1  output file for the decompiled C
//   2  optional per-function timeout in seconds (default 120)
//
// Run through tools/decompile.sh, which wires up analyzeHeadless.

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;

public class DecompileAt extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) {
            println("usage: DecompileAt.java <addrs.txt> <out.c> [timeoutSeconds]");
            return;
        }
        int timeout = args.length > 2 ? Integer.parseInt(args[2]) : 120;

        List<String> addresses = new ArrayList<String>();
        BufferedReader reader = new BufferedReader(new FileReader(args[0]));
        try {
            String line;
            while ((line = reader.readLine()) != null) {
                line = line.trim();
                if (line.length() > 0) {
                    addresses.add(line);
                }
            }
        }
        finally {
            reader.close();
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);

        PrintWriter out = new PrintWriter(new FileWriter(args[1]));
        try {
            for (String text : addresses) {
                Address address = toAddr(text);
                Function function = getFunctionContaining(address);
                if (function == null) {
                    out.println("### NOFUNC " + text);
                    continue;
                }
                out.println();
                out.println("### " + text + " -> " + function.getName() + " @ " + function.getEntryPoint());
                DecompileResults results = decompiler.decompileFunction(function, timeout, monitor);
                if (results != null && results.decompileCompleted()) {
                    out.println(results.getDecompiledFunction().getC());
                }
                else {
                    out.println("[[decompile failed]]");
                }
            }
        }
        finally {
            out.close();
        }
        println("DECOMPILE_AT_DONE " + addresses.size());
    }
}
