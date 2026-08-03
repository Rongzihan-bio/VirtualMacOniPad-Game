// Decompile the IOUserEthernet entry points which authorize a new client.
// @category VirtualMac

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

public class DumpIOUserEthernetAuthorization extends GhidraScript {
    private boolean isAuthorizationTarget(Function function) {
        String name = function.getName(true);
        return (name.contains("IOUserEthernetResourceUserClient") &&
                name.contains("initWithTask")) ||
               (name.contains("IOUserEthernetResource") &&
                name.contains("newUserClient"));
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1)
            throw new IllegalArgumentException("expected output directory");

        File outputDir = new File(args[0]);
        outputDir.mkdirs();
        List<Function> targets = new ArrayList<>();
        FunctionIterator functions =
            currentProgram.getFunctionManager().getFunctions(true);
        while (functions.hasNext()) {
            Function function = functions.next();
            if (isAuthorizationTarget(function))
                targets.add(function);
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        StringBuilder report = new StringBuilder();
        report.append("program: ").append(currentProgram.getName())
              .append("\nsha256: ")
              .append(currentProgram.getExecutableSHA256()).append("\n\n");

        for (Function function : targets) {
            report.append("===== ").append(function.getName(true))
                  .append(" @ ").append(function.getEntryPoint())
                  .append(" =====\n");
            DecompileResults result =
                decompiler.decompileFunction(function, 180, monitor);
            if (result.decompileCompleted())
                report.append(result.getDecompiledFunction().getC());
            else
                report.append("Decompiler failed: ")
                      .append(result.getErrorMessage()).append("\n");
            report.append("\n");
        }
        decompiler.dispose();

        if (targets.isEmpty())
            report.append("No authorization functions found.\n");
        File output = new File(outputDir,
            currentProgram.getName() + "-authorization.c");
        Files.writeString(output.toPath(), report.toString(),
                          StandardCharsets.UTF_8);
        println("wrote " + output.getAbsolutePath());
    }
}
