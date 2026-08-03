"""Trace Ventura VMM USB controller commands at the reconstructed handlers.

Usage after attaching LLDB before VMM initialization:
    command script import trace_usb_hci_commands.py
    vz_usb_trace_install
    continue
"""

import lldb
import struct


LOG = "/tmp/vz-usb-command-trace.log"
VMM_NAME = "com.apple.Virtualization.VirtualMachine"
COMMAND_HANDLER_OFFSET = 0x109E88
DOORBELL_HANDLER_OFFSET = 0x109EF4
ENDPOINT_RINGS = {}


def _append(line):
    with open(LOG, "a", encoding="utf-8") as output:
        output.write(line + "\n")


def _register(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()


def _read(process, address, size):
    error = lldb.SBError()
    data = process.ReadMemory(address, size, error)
    return data if error.Success() else b""


def _hex(data):
    return " ".join(f"{value:02x}" for value in data)


def _dump_ring(process, address, prefix):
    visited = set()
    current = address
    for segment in range(8):
        if not current or current in visited:
            break
        visited.add(current)
        ring = _read(process, current, 16 * 16)
        followed = 0
        for index in range(len(ring) // 16):
            item_control, item_data0, item_data1 = struct.unpack_from(
                "<IIQ", ring, index * 16
            )
            _append(
                f"{prefix}.segment{segment}[{index}] "
                f"type=0x{item_control & 0x3f:02x} "
                f"control=0x{item_control:08x} data0=0x{item_data0:08x} "
                f"data1=0x{item_data1:016x}"
            )
            if (item_control & 0x3F) == 0x3C:
                if item_control & 0x8000:
                    followed = item_data1
                break
        current = followed


def command_hit(frame, _location, _dictionary):
    process = frame.GetThread().GetProcess()
    packed = _register(frame, "x2")
    data1 = _register(frame, "x3")
    control = packed & 0xFFFFFFFF
    data0 = packed >> 32
    message_type = control & 0x3F
    _append(
        f"command type=0x{message_type:02x} control=0x{control:08x} "
        f"data0=0x{data0:08x} data1=0x{data1:016x}"
    )
    if message_type in (0x24, 0x28, 0x2C) and data1:
        _append(f"descriptor {_hex(_read(process, data1, 64))}")
    if message_type == 0x2E and data1:
        ENDPOINT_RINGS[data0] = data1
        _dump_ring(process, data1, "set-ring")
    return False


def doorbell_hit(frame, _location, _dictionary):
    process = frame.GetThread().GetProcess()
    address = _register(frame, "x2")
    count = _register(frame, "x3") & 0xFFFFFFFF
    data = _read(process, address, min(count, 64) * 4)
    values = [
        struct.unpack_from("<I", data, index * 4)[0]
        for index in range(len(data) // 4)
    ]
    _append("doorbell " + " ".join(f"0x{value:08x}" for value in values))
    for value in values:
        ring = ENDPOINT_RINGS.get(value)
        if ring:
            _dump_ring(process, ring, f"doorbell-0x{value:08x}")
    return False


def install(debugger, _command, result, _dictionary):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    module = next(
        (module for module in target.modules if module.file.basename == VMM_NAME),
        None,
    )
    if module is None:
        result.SetError("VMM module is not loaded")
        return
    base = module.GetObjectFileHeaderAddress().GetLoadAddress(target)
    with open(LOG, "w", encoding="utf-8") as output:
        output.write(f"pid={process.id} base=0x{base:x}\n")
    command_breakpoint = target.BreakpointCreateByAddress(
        base + COMMAND_HANDLER_OFFSET
    )
    command_breakpoint.SetScriptCallbackFunction(
        "trace_usb_hci_commands.command_hit"
    )
    doorbell_breakpoint = target.BreakpointCreateByAddress(
        base + DOORBELL_HANDLER_OFFSET
    )
    doorbell_breakpoint.SetScriptCallbackFunction(
        "trace_usb_hci_commands.doorbell_hit"
    )
    result.AppendMessage(
        f"USB trace installed at base 0x{base:x}; log={LOG}"
    )


def __lldb_init_module(debugger, _dictionary):
    debugger.HandleCommand(
        "command script add -f trace_usb_hci_commands.install "
        "vz_usb_trace_install"
    )
