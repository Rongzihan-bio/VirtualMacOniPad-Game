import lldb


def _register(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()


def _backtrace(frame, count):
    thread = frame.GetThread()
    for index in range(min(thread.GetNumFrames(), count)):
        item = thread.GetFrameAtIndex(index)
        module = item.GetModule().GetFileSpec().GetFilename() or "?"
        function = item.GetFunctionName() or item.GetDisplayFunctionName() or "?"
        print(f"  #{index} {module}`{function} @ {item.GetPCAddress()}")


def _cstring(frame, register):
    address = _register(frame, register)
    error = lldb.SBError()
    value = frame.GetThread().GetProcess().ReadCStringFromMemory(
        address, 1024, error
    )
    return value if error.Success() else f"<unreadable 0x{address:x}: {error}>"


def _object(frame, register):
    address = _register(frame, register)
    value = frame.EvaluateExpression(f"(id)0x{address:x}")
    return value.GetObjectDescription() or value.GetSummary() or str(value)


def dlsym(frame, _location, _dict):
    print(f"=== dlsym {_cstring(frame, 'x1')} ===")
    _backtrace(frame, 5)
    return False


def register_notifications(frame, _location, _dict):
    print("=== AMRestorableDeviceRegisterForNotifications ===")
    _backtrace(frame, 12)
    return False


def get_location(frame, _location, _dict):
    print("=== AMRestorableDeviceGetLocationID ===")
    _backtrace(frame, 8)
    return False


def default_restore_options(frame, _location, _dict):
    print("=== AMRestorableDeviceCopyDefaultRestoreOptions ===")
    _backtrace(frame, 8)
    return False


def restore(frame, _location, _dict):
    print("=== AMRestorableDeviceRestoreWithError ===")
    print(f"options: {_object(frame, 'x1')}")
    _backtrace(frame, 16)
    return False


def matching_services(frame, _location, _dict):
    print("=== IOServiceGetMatchingServices ===")
    print(f"matching: {_object(frame, 'x1')}")
    _backtrace(frame, 8)
    return False


def service_open(frame, _location, _dict):
    values = " ".join(
        f"{name}=0x{_register(frame, name):x}" for name in ("x0", "x1", "x2", "x3")
    )
    print(f"=== IOServiceOpen {values} ===")
    _backtrace(frame, 8)
    return False


def spawn(frame, _location, _dict):
    print(f"=== posix_spawn {_cstring(frame, 'x1')} ===")
    _backtrace(frame, 8)
    return False
