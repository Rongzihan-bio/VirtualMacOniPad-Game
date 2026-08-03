// Decompile the iPadOS 16.3.1 AMFI entitlement-query overloads used by
// IOUserEthernet. Addresses are from the iPad14,3-6 20D67 kernelcache.
// @category VirtualMac

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;

public class DumpAMFIEntitlements extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1)
            throw new IllegalArgumentException("expected output directory");

        Map<String, Long> targets = new LinkedHashMap<>();
        targets.put("AMFIEntitlementGetBool_proc", 0xfffffe00092b5e34L);
        targets.put("AMFIEntitlementGetBool_OSEntitlements",
                    0xfffffe00092b5eb4L);
        targets.put("AMFIEntitlementGetBool_ucred", 0xfffffe00092b5fccL);
        targets.put("OSEntitlements_initWithValidationResult",
                    0xfffffe00092b1858L);
        targets.put("OSEntitlements_queryEntitlementsFor",
                    0xfffffe00092b1cbcL);
        targets.put("OSEntitlements_markAsCSPlatform",
                    0xfffffe00092b2318L);
        targets.put("OSEntitlements_isCSPlatform", 0xfffffe00092b235cL);
        targets.put("getEntitlements_ucred", 0xfffffe00092b2834L);
        targets.put("copyEntitlements_ucred", 0xfffffe00092b2860L);
        targets.put("copyEntitlements_proc", 0xfffffe00092b28dcL);
        targets.put("loadEntitlementsFromSignature",
                    0xfffffe00092ba44cL);
        targets.put("postValidation", 0xfffffe00092ba710L);

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        StringBuilder report = new StringBuilder();
        for (Map.Entry<String, Long> target : targets.entrySet()) {
            Address address = toAddr(target.getValue());
            Function function = getFunctionAt(address);
            if (function == null)
                function = getFunctionContaining(address);
            report.append("===== ").append(target.getKey()).append(" @ ")
                .append(address).append(" =====\n");
            if (function == null) {
                report.append("No function found.\n\n");
                continue;
            }
            report.append("function: ").append(function.getName())
                .append(" entry=").append(function.getEntryPoint())
                .append("\n");
            DecompileResults result = decompiler.decompileFunction(
                function, 120, monitor);
            if (!result.decompileCompleted()) {
                report.append("Decompiler failed: ")
                    .append(result.getErrorMessage()).append("\n\n");
                continue;
            }
            report.append(result.getDecompiledFunction().getC())
                .append("\n\n");
        }
        decompiler.dispose();

        File outputDir = new File(args[0]);
        outputDir.mkdirs();
        File output = new File(outputDir, "AMFIEntitlementGetBool.c");
        Files.writeString(output.toPath(), report.toString(),
                          StandardCharsets.UTF_8);
        println("wrote " + output.getAbsolutePath());
    }
}
