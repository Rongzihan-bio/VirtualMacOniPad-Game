// Decompile the small set of extracted Virtualization/VMM functions involved
// in UIKit presentation, cursor rendering, input translation, and AVP HID.
// @category VirtualMac

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;

public class DumpTargetFunctions extends GhidraScript {
    private Map<String, Long> virtualizationTargets() {
        Map<String, Long> targets = new LinkedHashMap<>();
        targets.put("keyboard_sendKeyEvents", 0x100072d70L);
        targets.put("pointer_sendPointerEvents", 0x1000a7888L);
        targets.put("framebuffer_cursor", 0x1000ab408L);
        targets.put("framebuffer_setCursor", 0x1000ab3fcL);
        targets.put("framebuffer_didUpdateCursor", 0x1000ab418L);
        targets.put("framebuffer_applyCursorUpdate", 0x1000ab60cL);
        targets.put("framebuffer_applyCursorUpdateAsync", 0x1000ab9acL);
        targets.put("framebuffer_updateCursorGeometry", 0x1000abab8L);
        targets.put("framebuffer_updateCursorVisibility", 0x1000abc7cL);
        targets.put("framebuffer_didUpdateFrame", 0x1000abed0L);
        targets.put("framebuffer_applyFrameUpdate", 0x1000ac0c4L);
        targets.put("framebuffer_applyFrameUpdateAsync", 0x1000ac200L);
        targets.put("framebuffer_layout", 0x1000ac868L);
        targets.put("framebuffer_setShowsCursor", 0x1000ac930L);
        targets.put("framebuffer_initWithFrame", 0x1000acd00L);
        targets.put("framebuffer_finishInit", 0x1000acbe0L);
        targets.put("host_platform_configuration", 0x100075ad4L);
        return targets;
    }

    private Map<String, Long> vmmTargets() {
        Map<String, Long> targets = new LinkedHashMap<>();
        targets.put("rpc_keyboard", 0x10002ece4L);
        targets.put("rpc_digitizer", 0x10002f7f8L);
        targets.put("rpc_keyboard_dispatch", 0x1000df65cL);
        targets.put("rpc_digitizer_dispatch", 0x1000df5a4L);
        targets.put("hid_digitizer_event", 0x1000414c4L);
        targets.put("avp_screen_digitizer_event", 0x100121e3cL);
        targets.put("avp_relative_pointer_event", 0x10012203cL);
        targets.put("avp_hid_submit_event", 0x100122fc0L);
        targets.put("avp_keyboard_event", 0x100063cbcL);
        targets.put("avp_hid_enqueue", 0x10012ddacL);
        targets.put("avp_hid_async_drain", 0x10012deb4L);
        targets.put("pci_device_registration", 0x100179d50L);
        targets.put("pvg_create_task_callback", 0x10011e854L);
        targets.put("pvg_map_memory_callback", 0x10011e8c0L);
        targets.put("pvg_read_memory_callback", 0x10011eac8L);
        targets.put("pvg_destroy_task_callback", 0x10011eba0L);
        return targets;
    }

    private Map<String, Long> pvgTargets() {
        Map<String, Long> targets = new LinkedHashMap<>();
        // The first address is the helper which raises "Invalid task".  The
        // second is the recovered NSException catch site observed in the VMM.
        targets.put("invalid_task_throw", 0x100010a00L);
        targets.put("invalid_task_catch", 0x10001eb34L);
        targets.put("invalid_task_command", 0x10001e9d8L);
        targets.put("create_task", 0x10001082cL);
        targets.put("delete_task", 0x100010aa8L);
        targets.put("cmd_define_task", 0x100020004L);
        targets.put("cmd_delete_task", 0x10001dc44L);
        // Include the neighboring task and IOSurface code so the decompiler
        // can expose the state which makes the task lookup fail.
        targets.put("task_lookup_before", 0x100010800L);
        targets.put("task_lookup_after", 0x100010c00L);
        targets.put("surface_catch_before", 0x10001e800L);
        targets.put("surface_catch_after", 0x10001ed00L);
        return targets;
    }

    private Map<String, Long> vmnetTargets() {
        Map<String, Long> targets = new LinkedHashMap<>();
        targets.put("vmnet_start_interface", 0x100004000L);
        targets.put("vmnet_start_register_interface", 0x1000048fcL);
        targets.put("vmnet_start_async", 0x1000049b8L);
        targets.put("vmnet_start_netrb", 0x100004b3cL);
        targets.put("vmnet_interface_set_event_callback", 0x100005480L);
        targets.put("vmnet_stop_interface", 0x100005f38L);
        return targets;
    }

    private Map<String, Long> netrbTargets() {
        Map<String, Long> targets = new LinkedHashMap<>();
        targets.put("NETRBXPCEndPointCreate", 0x1e90ed428L);
        targets.put("NETRBXPCCreate", 0x1e90ed668L);
        targets.put("NETRBXPCSetupAndSend", 0x1e90ed91cL);
        targets.put("NETRBClientCreate", 0x1e90eddbcL);
        targets.put("NETRBClientCreate_connection", 0x1e90ee010L);
        targets.put("NETRBClientCreate_response", 0x1e90ee28cL);
        return targets;
    }

    private Map<String, Long> netrbMacTargets() {
        Map<String, Long> targets = new LinkedHashMap<>();
        targets.put("NETRBXPCCreate", 0x1babd0bf0L);
        targets.put("NETRBXPCSetupAndSend", 0x1babd0ea4L);
        targets.put("NETRBClientCreate", 0x1babd1360L);
        targets.put("NETRBClientNewInterface", 0x1babd3c0cL);
        targets.put("NETRBClientNewInterface_send", 0x1babd40d0L);
        targets.put("NETRBClientNewInterface_reply", 0x1babd43c0L);
        targets.put("NETRBClientHandleReply", 0x1babd27d0L);
        targets.put("NETRBClientStartService", 0x1babd1dd8L);
        return targets;
    }

    private Map<String, Long> internetSharingTargets() {
        Map<String, Long> targets = new LinkedHashMap<>();
        targets.put("cleanup_and_exit", 0x1000032a4L);
        targets.put("main", 0x1000033bcL);
        targets.put("start_xpc_listener", 0x10000394cL);
        targets.put("xpc_message_dispatch", 0x100003f10L);
        targets.put("create_interface", 0x1000052d8L);
        targets.put("create_network_service", 0x100006380L);
        targets.put("destroy_network_service", 0x100006140L);
        targets.put("service_interface_create", 0x100007198L);
        targets.put("configure_network_service", 0x1000078e0L);
        targets.put("allocate_bridge_name", 0x10001b96cL);
        targets.put("ethernet_controller_create", 0x100009fe0L);
        targets.put("ethernet_bsd_attach_callback", 0x10000a334L);
        targets.put("interface_broadcast_create", 0x10000ef64L);
        targets.put("interface_direct_create", 0x100010580L);
        targets.put("launchd_job_load", 0x10000d7d4L);
        targets.put("mis_bcast_init", 0x1000183f0L);
        targets.put("mis_dns_init", 0x1000199acL);
        targets.put("mis_bridge_add_member", 0x10001b24cL);
        targets.put("mis_bridge_create", 0x10001bc5cL);
        targets.put("mis_dhcp_init", 0x10001dbb8L);
        targets.put("settings_init", 0x100015cc4L);
        targets.put("bootpd_configuration_init", 0x100017e64L);
        targets.put("bootpd_configuration_cleanup", 0x1000182dcL);
        targets.put("broadcast_init", 0x10000eeccL);
        targets.put("xpc_listener_init", 0x10001a78cL);
        targets.put("startup_prerequisite", 0x10001cc54L);
        targets.put("log_message", 0x10001cd48L);
        return targets;
    }

    private Map<String, Long> installationTargets() {
        Map<String, Long> targets = new LinkedHashMap<>();
        targets.put("mobile_device_notification", 0x1000046b4L);
        targets.put("mobile_device_progress", 0x1000054a8L);
        targets.put("start_install", 0x10000b394L);
        targets.put("set_usb_controller_location_id", 0x10000c760L);
        targets.put("request_mobile_device_update", 0x10000cda0L);
        targets.put("load_restore_image_catalog", 0x10000dce8L);
        targets.put("load_restore_image", 0x1000101f4L);
        targets.put("service_connection", 0x100010a90L);
        return targets;
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1)
            throw new IllegalArgumentException("expected output directory");
        File outputDir = new File(args[0]);
        outputDir.mkdirs();

        String programName = currentProgram.getName();
        Map<String, Long> targets;
        if (programName.equals("Virtualization"))
            targets = virtualizationTargets();
        else if (programName.equals("ParavirtualizedGraphics"))
            targets = pvgTargets();
        else if (programName.equals("vmnet"))
            targets = vmnetTargets();
        else if (programName.equals("Netrb"))
            targets = netrbTargets();
        else if (programName.startsWith("Netrb.macos"))
            targets = netrbMacTargets();
        else if (programName.equals("InternetSharing"))
            targets = internetSharingTargets();
        else if (programName.startsWith(
                     "com.apple.Virtualization.Installation"))
            targets = installationTargets();
        else
            targets = vmmTargets();
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);

        StringBuilder report = new StringBuilder();
        report.append("program: ").append(programName).append("\n\n");
        if (programName.equals("ParavirtualizedGraphics")) {
            report.append("===== task-related-functions =====\n");
            FunctionIterator functions =
                currentProgram.getFunctionManager().getFunctions(true);
            while (functions.hasNext()) {
                Function function = functions.next();
                String name = function.getName();
                if (name.contains("TaskID") ||
                    name.contains("DefineTask") ||
                    name.contains("DeleteTask")) {
                    report.append(function.getEntryPoint()).append(" ")
                        .append(name).append("\n");
                }
            }
            report.append("\n");
        }
        for (Map.Entry<String, Long> target : targets.entrySet()) {
            Address address = toAddr(target.getValue());
            Function function = getFunctionAt(address);
            if (function == null)
                function = getFunctionContaining(address);
            report.append("===== ").append(target.getKey())
                .append(" @ ").append(address).append(" =====\n");
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

        File output = new File(outputDir, programName + "-targets.c");
        Files.writeString(output.toPath(), report.toString(),
                          StandardCharsets.UTF_8);
        println("wrote " + output.getAbsolutePath());
    }
}
