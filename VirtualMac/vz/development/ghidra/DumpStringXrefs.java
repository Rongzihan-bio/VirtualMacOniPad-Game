// Decompile every function which references a string containing the supplied
// text. This is useful for frameworks whose stripped functions have no stable 
// symbol name but do retain diagnostic exception strings.
// @category VirtualMac

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.ArrayDeque;
import java.util.HashSet;

public class DumpStringXrefs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 2)
            throw new IllegalArgumentException("expected search text and output file");

        String needle = args[0];
        File output = new File(args[1]);
        Set<Function> functions = new LinkedHashSet<>();
        StringBuilder report = new StringBuilder();
        report.append("program: ").append(currentProgram.getName())
            .append("\nsearch: ").append(needle).append("\n\n");

        DataIterator data = currentProgram.getListing().getDefinedData(true);
        while (data.hasNext() && !monitor.isCancelled()) {
            Data item = data.next();
            String value = item.getDefaultValueRepresentation();
            if (value == null || !value.contains(needle))
                continue;
            report.append("string ").append(item.getAddress()).append(" ")
                .append(value).append("\n");
            ArrayDeque<Address> pending = new ArrayDeque<>();
            Set<Address> visited = new HashSet<>();
            pending.add(item.getAddress());
            for (int depth = 0; depth < 4 && !pending.isEmpty(); depth++) {
                int count = pending.size();
                while (count-- > 0) {
                    Address target = pending.remove();
                    if (!visited.add(target))
                        continue;
                    ReferenceIterator references = currentProgram
                        .getReferenceManager().getReferencesTo(target);
                    while (references.hasNext()) {
                        Reference reference = references.next();
                        Address from = reference.getFromAddress();
                        Function function = getFunctionContaining(from);
                        report.append("  xref depth=").append(depth)
                            .append(" ").append(from)
                            .append(" function=").append(function).append("\n");
                        if (function != null) {
                            functions.add(function);
                            continue;
                        }
                        Data container = currentProgram.getListing()
                            .getDataContaining(from);
                        pending.add(container != null
                            ? container.getAddress() : from);
                    }
                }
            }
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        for (Function function : functions) {
            report.append("\n===== ").append(function.getName()).append(" @ ")
                .append(function.getEntryPoint()).append(" =====\n");
            DecompileResults result = decompiler.decompileFunction(
                function, 180, monitor);
            if (result.decompileCompleted())
                report.append(result.getDecompiledFunction().getC());
            else
                report.append("Decompiler failed: ")
                    .append(result.getErrorMessage()).append("\n");
        }
        decompiler.dispose();

        output.getParentFile().mkdirs();
        Files.writeString(output.toPath(), report.toString(),
                          StandardCharsets.UTF_8);
        println("wrote " + output.getAbsolutePath());
    }
}
