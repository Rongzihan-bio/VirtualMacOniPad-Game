// Decompile every function referencing one of the requested string fragments.
// @category VirtualMac

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;

public class DumpStringReferenceFunctions extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2)
            throw new IllegalArgumentException(
                "expected output file followed by string fragments");
        Map<String, Function> functions = new LinkedHashMap<>();
        DataIterator data = currentProgram.getListing().getDefinedData(true);
        while (data.hasNext()) {
            Data item = data.next();
            Object value = item.getValue();
            if (!(value instanceof String))
                continue;
            String text = (String)value;
            boolean wanted = false;
            for (int i = 1; i < args.length; i++)
                wanted |= text.contains(args[i]);
            if (!wanted)
                continue;
            ReferenceIterator refs = currentProgram.getReferenceManager()
                .getReferencesTo(item.getMinAddress());
            while (refs.hasNext()) {
                Reference ref = refs.next();
                Function function = getFunctionContaining(ref.getFromAddress());
                if (function != null)
                    functions.put(function.getEntryPoint().toString(), function);
            }
        }
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        StringBuilder report = new StringBuilder();
        for (Map.Entry<String, Function> entry : functions.entrySet()) {
            Function function = entry.getValue();
            report.append("===== ").append(function.getName()).append(" @ ")
                .append(entry.getKey()).append(" =====\n");
            DecompileResults result = decompiler.decompileFunction(
                function, 120, monitor);
            report.append(result.decompileCompleted()
                ? result.getDecompiledFunction().getC()
                : result.getErrorMessage()).append("\n\n");
        }
        decompiler.dispose();
        Files.writeString(new File(args[0]).toPath(), report.toString(),
                          StandardCharsets.UTF_8);
    }
}
