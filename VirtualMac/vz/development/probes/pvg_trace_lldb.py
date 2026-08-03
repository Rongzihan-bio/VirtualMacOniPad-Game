import lldb


PVG_OFFSETS = {
    "init-entry": 0xE94C,
    "first-setup-result": 0xEC20,
    "second-setup-result": 0xEC2C,
    "init-failure": 0xEC3C,
    "init-success": 0xEC48,
    "blit-entry": 0xECD4,
    "blit-bundle": 0xED1C,
    "display-bundle": 0xE6D0,
    "blit-library-call": 0xED24,
    "blit-library-result": 0xED2C,
    "blit-in-function-result": 0xED44,
    "blit-in-pipeline-result": 0xED58,
    "blit-out-function-result": 0xED70,
    "blit-out-pipeline-result": 0xED84,
    "blit-in-error": 0xED90,
    "blit-out-error": 0xEDB8,
    "blit-result": 0xEDD4,
    "reporting-entry": 0xEE04,
    "reporting-result": 0xEEE0,
    "library-selector-stub": 0x3E6C8,
}

BREAKPOINT_NAMES = {}
USE_SYSTEM_RESOURCE_BUNDLE = False
USE_MAIN_RESOURCE_BUNDLE = False


def _register(frame, name):
    value = frame.FindRegister(name)
    return value.GetValue() if value.IsValid() else "?"


def trace_callback(frame, bp_loc, _internal_dict):
    bp_id = bp_loc.GetBreakpoint().GetID()
    name = BREAKPOINT_NAMES.get(bp_id, "unknown")
    print(
        "PVG_BREAK\t{}\tpc={}\tx0={}\tx2={}\tx19={}\tx20={}\tsp={}".format(
            name,
            _register(frame, "pc"),
            _register(frame, "x0"),
            _register(frame, "x2"),
            _register(frame, "x19"),
            _register(frame, "x20"),
            _register(frame, "sp"),
        ),
        flush=True,
    )
    if name in {
        "blit-bundle-and-device",
        "blit-library-result",
        "blit-in-pipeline-result",
        "blit-out-pipeline-result",
        "blit-in-error",
        "blit-out-error",
    }:
        error = frame.EvaluateExpression(
            "(id)*(void **)($sp + 8)",
            lldb.SBExpressionOptions(),
        )
        print(
            "PVG_ERROR\t{}\tvalue={}\tdescription={}".format(
                name,
                error.GetValue() or "?",
                error.GetObjectDescription() or "?",
            ),
            flush=True,
        )
    if name in {"blit-bundle", "blit-bundle-and-device", "blit-device"}:
        device = frame.EvaluateExpression("(id)$x0")
        bundle = frame.EvaluateExpression("(id)$x2")
        bundle_path = frame.EvaluateExpression("[(id)$x2 bundlePath]")
        print(
            "PVG_OBJECTS\tdevice={}\tbundle={}\tbundlePath={}".format(
                device.GetObjectDescription() or "?",
                bundle.GetObjectDescription() or "?",
                bundle_path.GetObjectDescription() or "?",
            ),
            flush=True,
        )
        if name == "blit-device":
            cls = frame.EvaluateExpression("(void *)[(id)$x0 class]")
            implementation = frame.EvaluateExpression(
                "(void *)[(id)$x0 "
                "methodForSelector:@selector(newDefaultLibraryWithBundle:error:)]"
            )
            print(
                "PVG_DEVICE\tclass={}\timplementation={}".format(
                    cls.GetValue() or "?",
                    implementation.GetValue() or "?",
                ),
                flush=True,
            )
    if name in {"blit-bundle", "display-bundle"} and USE_SYSTEM_RESOURCE_BUNDLE:
        system_bundle = frame.EvaluateExpression(
            "(void *)[NSBundle bundleWithPath:"
            '@"/System/Library/Frameworks/ParavirtualizedGraphics.framework"]'
        )
        pointer = system_bundle.GetValue()
        changed = frame.FindRegister("x2").SetValueFromCString(pointer)
        print(
            "PVG_OVERRIDE\tsystem-resource-bundle={}\tchanged={}".format(
                pointer,
                changed,
            ),
            flush=True,
        )
    if name in {"blit-bundle", "display-bundle"} and USE_MAIN_RESOURCE_BUNDLE:
        main_bundle = frame.EvaluateExpression("(void *)[NSBundle mainBundle]")
        pointer = main_bundle.GetValue()
        changed = frame.FindRegister("x2").SetValueFromCString(pointer)
        print(
            "PVG_OVERRIDE\tmain-resource-bundle={}\tchanged={}".format(
                pointer,
                changed,
            ),
            flush=True,
        )
    if name == "library-selector-stub":
        selector_name = frame.EvaluateExpression("(const char *)sel_getName((SEL)$x1)")
        implementation = frame.EvaluateExpression(
            "(void *)[(id)$x0 methodForSelector:(SEL)$x1]"
        )
        print(
            "PVG_SELECTOR\tx1={}\tname={}\timplementation={}".format(
                _register(frame, "x1"),
                selector_name.GetSummary() or selector_name.GetValue() or "?",
                implementation.GetValue() or "?",
            ),
            flush=True,
        )
    if name == "blit-library-call":
        process = frame.GetThread().GetProcess()
        error = lldb.SBError()
        pc = int(_register(frame, "pc"), 16)
        instruction = process.ReadUnsignedFromMemory(pc, 4, error)
        immediate = instruction & 0x03FFFFFF
        if immediate & 0x02000000:
            immediate -= 0x04000000
        target = pc + immediate * 4
        print(
            "PVG_CALL\tinstruction=0x{:08x}\ttarget=0x{:x}\terror={}".format(
                instruction,
                target,
                error.GetCString() or "none",
            ),
            flush=True,
        )
    return False


def install_pvg_breakpoints(debugger, _command, result, _internal_dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    module = None
    debugger.SetAsync(False)
    debugger.HandleCommand(
        "settings set target.process.stop-on-sharedlibrary-events true"
    )

    for _ in range(512):
        for candidate in target.module_iter():
            if candidate.GetFileSpec().GetFilename() == "ParavirtualizedGraphics":
                module = candidate
                break
        if module is not None:
            break
        if process.GetState() != lldb.eStateStopped:
            result.SetError("VMM stopped before ParavirtualizedGraphics loaded")
            return
        process.Continue()

    if module is None:
        result.SetError("ParavirtualizedGraphics did not load")
        return

    header = module.GetObjectFileHeaderAddress().GetLoadAddress(target)
    print("PVG_MODULE\tbase=0x{:x}\tpath={}".format(header, module.GetFileSpec()), flush=True)
    for name, offset in PVG_OFFSETS.items():
        breakpoint = target.BreakpointCreateByAddress(header + offset)
        breakpoint.SetScriptCallbackFunction(
            "pvg_trace_lldb.trace_callback"
        )
        BREAKPOINT_NAMES[breakpoint.GetID()] = name
        print(
            "PVG_BP\t{}\tid={}\taddress=0x{:x}\tlocations={}".format(
                name,
                breakpoint.GetID(),
                header + offset,
                breakpoint.GetNumLocations(),
            ),
            flush=True,
        )

    debugger.HandleCommand(
        "settings set target.process.stop-on-sharedlibrary-events false"
    )
    result.AppendMessage("PVG breakpoints installed")


def __lldb_init_module(debugger, _internal_dict):
    debugger.HandleCommand(
        "command script add -f pvg_trace_lldb.install_pvg_breakpoints install-pvg-breakpoints"
    )
