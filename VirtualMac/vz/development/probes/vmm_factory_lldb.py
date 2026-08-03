import lldb


FACTORY_RESULT_OFFSET = 0x154F14
SEQUENCE = 0


def _register(frame, name):
    value = frame.FindRegister(name)
    text = value.GetValue()
    return int(text, 0) if text else 0


def _possible_strings(process, sp):
    found = []
    error = lldb.SBError()
    for offset in range(0x20, 0x120, 8):
        pointer = process.ReadUnsignedFromMemory(sp + offset, 8, error)
        if error.Fail() or pointer < 0x100000000:
            error.Clear()
            continue
        text = process.ReadCStringFromMemory(pointer, 160, error)
        if error.Success() and text and all(
            character.isprintable() or character in "\t\r\n"
            for character in text
        ):
            found.append("+0x{:x}=0x{:x}={!r}".format(offset, pointer, text))
        error.Clear()
    return found


def factory_result_callback(frame, _bp_loc, _internal_dict):
    global SEQUENCE
    SEQUENCE += 1
    process = frame.GetThread().GetProcess()
    sp = _register(frame, "sp")
    success = _register(frame, "x0")
    error = lldb.SBError()
    device = process.ReadUnsignedFromMemory(sp + 0xC0, 8, error)
    strings = _possible_strings(process, sp)
    print(
        "VMM_FACTORY\tsequence={}\tsuccess={}\tdevice=0x{:x}\tsp=0x{:x}"
        "\tstrings={}".format(
            SEQUENCE,
            success,
            device if error.Success() else 0,
            sp,
            " | ".join(strings) if strings else "-",
        ),
        flush=True,
    )
    return False


def install_factory_trace(debugger, _command, result, _internal_dict):
    target = debugger.GetSelectedTarget()
    module = None
    for candidate in target.module_iter():
        if (
            candidate.GetFileSpec().GetFilename()
            == "com.apple.Virtualization.VirtualMachine"
        ):
            module = candidate
            break
    if module is None:
        result.SetError("VMM image is not loaded")
        return

    base = module.GetObjectFileHeaderAddress().GetLoadAddress(target)
    breakpoint = target.BreakpointCreateByAddress(
        base + FACTORY_RESULT_OFFSET
    )
    breakpoint.SetScriptCallbackFunction(
        "vmm_factory_lldb.factory_result_callback"
    )
    result.AppendMessage(
        "VMM factory trace installed at 0x{:x}".format(
            base + FACTORY_RESULT_OFFSET
        )
    )


def __lldb_init_module(debugger, _internal_dict):
    debugger.HandleCommand(
        "command script add -f "
        "vmm_factory_lldb.install_factory_trace install-vmm-factory-trace"
    )
