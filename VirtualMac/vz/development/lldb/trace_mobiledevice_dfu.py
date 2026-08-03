"""Auto-continuing MobileDevice DFU construction trace for iPad LLDB.

Usage after attaching to com.apple.Virtualization.Installation:
  command script import /var/root/VirtualMac/lldb/trace_mobiledevice_dfu.py
  trace-mobiledevice-dfu
  continue
"""

import lldb
import time

LOG = "/tmp/mobiledevice-dfu-trace.log"
DESIRED_FILE_ADDRESS = 0x255620

MILESTONES = [
    (0x120, "create-plugin"),
    (0x180, "query-interface"),
    (0x1AC, "location"),
    (0x1C0, "vendor"),
    (0x1D4, "product"),
    (0x1EC, "manufacturer-index"),
    (0x218, "product-index"),
    (0x244, "serial-index"),
    (0x260, "strings-complete"),
    (0x280, "configuration"),
    (0x390, "descriptors-parsed"),
    (0x3BC, "device-accepted"),
    (0x3D0, "return"),
    (0x3F0, "device-rejected"),
]

_installed_addresses = set()


def _log(message):
    with open(LOG, "a", encoding="utf-8") as stream:
        stream.write(f"[{time.time():.6f}] {message}\n")


def _register(frame, name):
    value = frame.FindRegister(name)
    return value.GetValueAsUnsigned() if value.IsValid() else 0


def milestone_callback(frame, bp_loc, _dict):
    thread = frame.GetThread()
    process = thread.GetProcess()
    label = bp_loc.GetBreakpoint().GetName() or "milestone"
    x19 = _register(frame, "x19")
    w0 = _register(frame, "w0")
    detail = ""
    if x19:
        error = lldb.SBError()
        data = process.ReadMemory(x19 + 0x20, 16, error)
        if error.Success():
            detail = " object20=" + data.hex()
    _log(
        f"pid={process.GetProcessID()} {label} pc=0x{frame.GetPC():x} "
        f"w0=0x{w0:x} x19=0x{x19:x}{detail}"
    )
    return False


def entry_callback(frame, _bp_loc, _dict):
    address = frame.GetPCAddress()
    if address.GetFileAddress() != DESIRED_FILE_ADDRESS:
        return False
    target = frame.GetThread().GetProcess().GetTarget()
    base = address.GetLoadAddress(target)
    _log(f"pid={frame.GetThread().GetProcess().GetProcessID()} device-entry "
         f"load=0x{base:x}")
    for offset, label in MILESTONES:
        load_address = base + offset
        if load_address in _installed_addresses:
            continue
        breakpoint = target.BreakpointCreateByAddress(load_address)
        breakpoint.AddName(label)
        breakpoint.SetScriptCallbackFunction(
            "trace_mobiledevice_dfu.milestone_callback")
        _installed_addresses.add(load_address)
    return False


def trace_mobiledevice_dfu(debugger, _command, result, _dict):
    target = debugger.GetSelectedTarget()
    breakpoint = target.BreakpointCreateByName(
        "deviceWithService", "MobileDevice")
    breakpoint.AddName("dfu-device-entry")
    breakpoint.SetScriptCallbackFunction(
        "trace_mobiledevice_dfu.entry_callback")
    _log(f"armed entry breakpoint id={breakpoint.GetID()}")
    result.PutCString(
        f"MobileDevice DFU trace armed; log: {LOG}")


def __lldb_init_module(debugger, _dict):
    debugger.HandleCommand(
        "command script add -f trace_mobiledevice_dfu.trace_mobiledevice_dfu "
        "trace-mobiledevice-dfu")

