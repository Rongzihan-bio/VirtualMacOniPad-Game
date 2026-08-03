"""Trace IOUSBLib associated-descriptor results in a restore process.

Attach LLDB to com.apple.Virtualization.Installation, import this file, run
``vz_iousb_descriptor_trace_install``, and continue.  Ventura's arm64e
IOUSBHostFamily IOUSBLib has a single return at entry + 0x78 for this method.
"""

import lldb


LOG = "/tmp/vz-iousblib-descriptor-trace.log"
SYMBOL = "_ZN19IOUSBInterfaceClass28FindNextAssociatedDescriptorEPKvh"
CALLS = {}
RETURN_BREAKPOINT = None


def _append(line):
    with open(LOG, "a", encoding="utf-8") as output:
        output.write(line + "\n")


def _reg(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()


def _read(process, address, size):
    if not address:
        return b""
    error = lldb.SBError()
    data = process.ReadMemory(address, size, error)
    return data if error.Success() else b""


def _hex(data):
    return " ".join(f"{byte:02x}" for byte in data)


def entry_hit(frame, _location, _dictionary):
    global RETURN_BREAKPOINT
    thread = frame.GetThread()
    process = thread.GetProcess()
    descriptor_type = _reg(frame, "x2") & 0xFF
    CALLS[thread.id] = descriptor_type
    if RETURN_BREAKPOINT is None:
        target = process.GetTarget()
        return_address = frame.GetPC() + 0x78
        RETURN_BREAKPOINT = target.BreakpointCreateByAddress(return_address)
        RETURN_BREAKPOINT.SetScriptCallbackFunction(
            "trace_iousblib_descriptors.return_hit"
        )
        _append(f"return-breakpoint=0x{return_address:x}")
    return False


def return_hit(frame, _location, _dictionary):
    thread = frame.GetThread()
    descriptor_type = CALLS.pop(thread.id, None)
    if descriptor_type is None:
        return False
    result = _reg(frame, "x0")
    data = _read(thread.GetProcess(), result, 32)
    _append(
        f"type=0x{descriptor_type:02x} result=0x{result:x} bytes={_hex(data)}"
    )
    return False


def install(debugger, _command, result, _dictionary):
    global RETURN_BREAKPOINT
    CALLS.clear()
    RETURN_BREAKPOINT = None
    with open(LOG, "w", encoding="utf-8") as output:
        output.write("trace-started\n")
    target = debugger.GetSelectedTarget()
    breakpoint = target.BreakpointCreateByName(SYMBOL)
    breakpoint.SetScriptCallbackFunction(
        "trace_iousblib_descriptors.entry_hit"
    )
    result.AppendMessage(
        f"IOUSBLib descriptor trace installed; log={LOG}"
    )


def __lldb_init_module(debugger, _dictionary):
    debugger.HandleCommand(
        "command script add -f trace_iousblib_descriptors.install "
        "vz_iousb_descriptor_trace_install"
    )
