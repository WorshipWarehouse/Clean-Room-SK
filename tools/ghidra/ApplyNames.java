// Apply provisional function names from a TSV of address<TAB>name.
//
// Only functions that still carry a Ghidra generated name (FUN_ or thunk_FUN_)
// are renamed, so real symbols are never overwritten.
//
// Script arguments:
//   0  input TSV
//   1  optional output TSV of what was renamed

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.PrintWriter;

public class ApplyNames extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) {
            println("usage: ApplyNames.java <names.tsv> [renamed.tsv]");
            return;
        }

        int renamed = 0;
        int skipped = 0;
        PrintWriter record = null;
        if (args.length > 1) {
            record = new PrintWriter(new FileWriter(args[1]));
        }

        BufferedReader reader = new BufferedReader(new FileReader(args[0]));
        try {
            String line;
            while ((line = reader.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) {
                    continue;
                }
                String[] parts = line.split("\t");
                if (parts.length < 2) {
                    continue;
                }
                Address address = toAddr(parts[0]);
                Function function = getFunctionAt(address);
                if (function == null) {
                    function = getFunctionContaining(address);
                }
                if (function == null) {
                    skipped++;
                    continue;
                }
                String current = function.getName();
                if (!current.startsWith("FUN_") && !current.startsWith("thunk_FUN_")) {
                    skipped++;
                    continue;
                }
                try {
                    function.setName(parts[1], SourceType.USER_DEFINED);
                    renamed++;
                    if (record != null) {
                        record.println(function.getEntryPoint() + "\t" + parts[1]);
                    }
                }
                catch (Exception conflict) {
                    skipped++;
                }
            }
        }
        finally {
            reader.close();
            if (record != null) {
                record.close();
            }
        }
        println("APPLY_NAMES_DONE renamed=" + renamed + " skipped=" + skipped);
    }
}
