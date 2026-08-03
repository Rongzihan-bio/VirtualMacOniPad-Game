// Decompile functions containing requested addresses.
// Arguments after the output path are LABEL=ADDRESS pairs.
// @category VirtualMac

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

public class DumpAddressFunctions extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2)
            throw new IllegalArgumentException(
                "expected output file followed by LABEL=ADDRESS pairs");
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        StringBuilder report = new StringBuilder();
        report.append("program: ").append(currentProgram.getName())
              .append("\nsha256: ")
              .append(currentProgram.getExecutableSHA256()).append("\n\n");
        for (int index = 1; index < args.length; index++) {
            String[] pair = args[index].split("=", 2);
            if (pair.length != 2)
                throw new IllegalArgumentException("invalid target " + args[index]);
            Address address = toAddr(Long.decode(pair[1]));
            Function function = getFunctionAt(address);
            if (function == null)
                function = getFunctionContaining(address);
            report.append("===== ").append(pair[0]).append(" @ ")
                  .append(address).append(" =====\n");
            if (function == null) {
                report.append("No function found.\n\n");
                continue;
            }
            report.append("function: ").append(function.getName(true))
                  .append(" entry=").append(function.getEntryPoint())
                  .append("\n");
            DecompileResults result =
                decompiler.decompileFunction(function, 300, monitor);
            if (result.decompileCompleted())
                report.append(result.getDecompiledFunction().getC());
            else
                report.append("Decompiler failed: ")
                      .append(result.getErrorMessage()).append("\n");
            report.append("\n");
        }
        decompiler.dispose();
        File output = new File(args[0]);
        output.getParentFile().mkdirs();
        Files.writeString(output.toPath(), report.toString(),
                          StandardCharsets.UTF_8);
        println("wrote " + output.getAbsolutePath());
    }
}
