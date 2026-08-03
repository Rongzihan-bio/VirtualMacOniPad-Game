// Decompile functions whose Ghidra name contains the supplied text.
// @category VirtualMac

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

public class DumpNamedFunctions extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 2)
            throw new IllegalArgumentException("expected name text and output file");
        String needle = args[0];
        File output = new File(args[1]);
        StringBuilder report = new StringBuilder();
        report.append("program: ").append(currentProgram.getName())
            .append("\nfunction search: ").append(needle).append("\n\n");

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        FunctionIterator functions = currentProgram.getFunctionManager()
            .getFunctions(true);
        while (functions.hasNext() && !monitor.isCancelled()) {
            Function function = functions.next();
            if (!function.getName().contains(needle))
                continue;
            report.append("===== ").append(function.getName()).append(" @ ")
                .append(function.getEntryPoint()).append(" =====\n");
            DecompileResults result = decompiler.decompileFunction(
                function, 180, monitor);
            if (result.decompileCompleted())
                report.append(result.getDecompiledFunction().getC());
            else
                report.append("Decompiler failed: ")
                    .append(result.getErrorMessage()).append("\n");
            report.append("\n");
        }
        decompiler.dispose();
        output.getParentFile().mkdirs();
        Files.writeString(output.toPath(), report.toString(),
                          StandardCharsets.UTF_8);
        println("wrote " + output.getAbsolutePath());
    }
}
