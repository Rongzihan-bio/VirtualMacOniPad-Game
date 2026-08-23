#!/usr/bin/env python3
"""Exercise Virtualization.framework's private guest GDB stub.

This is a development probe, not part of the shipped app.  It intentionally
implements only the small acknowledged-packet subset used by Apple's stub so
bring-up does not depend on LLDB's kernel plugin.
"""

import argparse
import socket
import struct


def checksum(payload: bytes) -> bytes:
    return f"{sum(payload) & 0xff:02x}".encode("ascii")


class Remote:
    def __init__(self, host: str, port: int) -> None:
        self.socket = socket.create_connection((host, port), timeout=5)
        self.socket.settimeout(5)
        self.pending = bytearray()
        self.no_ack = False
        self.socket.sendall(b"+")

    def _receive_byte(self) -> int:
        if not self.pending:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise ConnectionError("GDB stub closed the connection")
            self.pending.extend(chunk)
        value = self.pending[0]
        del self.pending[0]
        return value

    def _receive_packet(self) -> bytes:
        while self._receive_byte() != ord("$"):
            pass
        payload = bytearray()
        while True:
            value = self._receive_byte()
            if value == ord("#"):
                break
            payload.append(value)
        received = bytes((self._receive_byte(), self._receive_byte()))
        if checksum(payload) != received.lower():
            self.socket.sendall(b"-")
            raise ValueError("GDB packet checksum mismatch")
        if not self.no_ack:
            self.socket.sendall(b"+")
        return bytes(payload)

    def request(self, text: str) -> bytes:
        payload = text.encode("ascii")
        self.socket.sendall(b"$" + payload + b"#" + checksum(payload))
        # Apple's stub acknowledges every request before sending its reply.
        if not self.no_ack:
            while self._receive_byte() != ord("+"):
                pass
        return self._receive_packet()

    def start_no_ack_mode(self) -> None:
        if self.request("QStartNoAckMode") != b"OK":
            raise RuntimeError("GDB stub refused no-ack mode")
        self.no_ack = True

    def close(self) -> None:
        try:
            try:
                print("detach:", self.request("D").decode("ascii", "replace"))
            except (ConnectionError, OSError, TimeoutError):
                pass
        finally:
            self.socket.close()

    def read_memory(self, address: int, length: int) -> bytes:
        result = bytearray()
        # Apple's endpoint supports large binary reads. A 256 KiB request was
        # validated on-device and makes whole-kernel pattern scans fast enough
        # to use during normal VM startup.
        while len(result) < length:
            amount = min(0x40000, length - len(result))
            current = address + len(result)
            # Use GDB's binary-memory command. An address beginning in `ffff`
            # makes the packet appear as `$xffff...` in LLDB packet logs: the
            # first `x` is the command, not part of the address.
            response = self.request(f"x{current:x},{amount:x}")
            if (len(response) == 3 and response.startswith(b"E") and
                    all(byte in b"0123456789abcdefABCDEF"
                        for byte in response[1:])):
                raise OSError(f"guest memory read failed: {response!r}")
            value = bytearray()
            position = 0
            while position < len(response):
                byte = response[position]
                position += 1
                if byte == ord("}"):
                    if position >= len(response):
                        raise OSError("truncated GDB binary escape")
                    byte = response[position] ^ 0x20
                    position += 1
                value.append(byte)
            if len(value) != amount:
                raise OSError(
                    f"short guest memory read: wanted {amount}, "
                    f"got {len(value)}")
            result.extend(value)
        return bytes(result)

    def write_memory(self, address: int, value: bytes) -> None:
        encoded = value.hex()
        response = self.request(f"M{address:x},{len(value):x}:{encoded}")
        if response != b"OK":
            raise OSError(f"guest memory write failed: {response!r}")

    def register(self, number: int) -> int:
        encoded = self.request(f"p{number:x}")
        return int.from_bytes(bytes.fromhex(encoded.decode("ascii")), "little")


MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
MH_FILESET = 12
LC_SEGMENT_64 = 0x19


def find_kernel(remote: Remote, pc: int) -> tuple[int, dict[str, tuple[int, int]]]:
    page = pc & ~0x3FFF
    for _ in range((128 * 1024 * 1024) // 0x4000):
        try:
            header = remote.read_memory(page, 32)
        except OSError:
            page -= 0x4000
            continue
        fields = struct.unpack("<IIIIIIII", header)
        magic, cpu_type, _, file_type, ncmds, sizeofcmds, _, _ = fields
        if (magic != MH_MAGIC_64 or cpu_type != CPU_TYPE_ARM64 or
                file_type not in (MH_EXECUTE, MH_FILESET) or
                not 0 < ncmds < 1000 or
                sizeofcmds > 1024 * 1024):
            page -= 0x4000
            continue
        commands = remote.read_memory(page + 32, sizeofcmds)
        segments: dict[str, tuple[int, int]] = {}
        offset = 0
        valid = True
        for _ in range(ncmds):
            if offset + 8 > len(commands):
                valid = False
                break
            command, size = struct.unpack_from("<II", commands, offset)
            if size < 8 or offset + size > len(commands):
                valid = False
                break
            if command == LC_SEGMENT_64 and size >= 72:
                raw_name = commands[offset + 8:offset + 24]
                name = raw_name.split(b"\0", 1)[0].decode("ascii", "replace")
                vm_address, vm_size = struct.unpack_from("<QQ", commands,
                                                         offset + 24)
                segments[name] = (vm_address, vm_size)
            offset += size
        if valid and "__TEXT" in segments and "__TEXT_EXEC" in segments:
            return page, segments
        page -= 0x4000
    raise RuntimeError("kernel Mach-O header not found")


def sign_extend(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


def decode_adrp(pc: int, instruction: int) -> int:
    immediate = (((instruction >> 5) & 0x7FFFF) << 2) | \
                ((instruction >> 29) & 3)
    return (pc & ~0xFFF) + (sign_extend(immediate, 21) << 12)


def scan_text(remote: Remote, start: int, size: int, callback):
    chunk_size = 0x40000
    overlap = 32
    offset = 0
    tail = b""
    while offset < size:
        amount = min(chunk_size, size - offset)
        chunk = remote.read_memory(start + offset, amount)
        data = tail + chunk
        data_address = start + offset - len(tail)
        for position in range((-data_address) & 3, len(data) - 28, 4):
            result = callback(data, position, data_address + position)
            if result is not None:
                return result
        tail = data[-overlap:]
        offset += amount
    return None


def find_boot_args_pointer(remote: Remote, start: int, size: int) -> int:
    prefix = struct.pack("<III", 0xAA0203E3, 0xAA0103E2, 0xAA0003E1)

    def match(data: bytes, position: int, pc: int):
        if data[position:position + 12] != prefix:
            return None
        adrp, add, load, command_line = struct.unpack_from("<IIII", data,
                                                           position + 12)
        if adrp & 0x9F00001F != 0x90000008:
            return None
        if add & 0xFFC003FF != 0x91000108:
            return None
        if load & 0xFFC003FF != 0xF9400108:
            return None
        if command_line != 0x9101B100:  # add x0, x8, #0x6c
            return None
        add_value = ((add >> 10) & 0xFFF) << (12 if add & (1 << 22) else 0)
        load_value = ((load >> 10) & 0xFFF) * 8
        return decode_adrp(pc + 12, adrp) + add_value + load_value

    result = scan_text(remote, start, size, match)
    if result is None:
        raise RuntimeError("PE_parse_boot_argn pattern not found")
    return result


def looks_like_boot_args(value: bytes) -> bool:
    """Validate the public XNU arm64 boot_args prefix and CommandLine."""
    if len(value) < 128:
        return False
    revision, version = struct.unpack_from("<HH", value)
    virtual_base, physical_base, memory_size, top = struct.unpack_from(
        "<QQQQ", value, 8)
    device_tree = struct.unpack_from("<Q", value, 96)[0]
    device_tree_length = struct.unpack_from("<I", value, 104)[0]
    command = value[108:128].split(b"\0", 1)[0]
    return (1 <= revision <= 4 and 1 <= version <= 2 and
            virtual_base & 0xFFF == 0 and physical_base & 0xFFF == 0 and
            128 << 20 <= memory_size <= 1 << 40 and
            physical_base <= top <= physical_base + memory_size and
            device_tree >= 0xFFFF_0000_0000_0000 and
            0 < device_tree_length <= 64 << 20 and
            all(0x20 <= byte <= 0x7E for byte in command))


def find_boot_args_pointer_by_data(
        remote: Remote, segments: dict[str, tuple[int, int]],
        slide: int) -> int:
    """Find PE_state.bootArgs without relying on compiler instruction order.

    XNU's boot_args prefix is public and stable, while PE_boot_args has been
    inlined differently across Monterey, Tahoe, and Golden Gate kernels.
    """
    live_segments = {
        name: (address + slide, size)
        for name, (address, size) in segments.items()
    }
    image_start = min(address for address, _ in live_segments.values())
    image_end = max(address + size
                    for address, size in live_segments.values())
    data_segments: list[tuple[int, bytes]] = []
    for name, (address, size) in live_segments.items():
        if ((name.startswith("__DATA") or name.startswith("__BOOTDATA")) and
                size <= 64 << 20):
            data_segments.append((address, remote.read_memory(address, size)))

    external: list[tuple[int, int]] = []
    internal: list[tuple[int, int]] = []
    seen_external: set[int] = set()
    seen_internal: set[int] = set()
    for address, contents in data_segments:
        for offset in range(0, len(contents) - 7, 8):
            target = struct.unpack_from("<Q", contents, offset)[0]
            if target < 0xFFFF_0000_0000_0000:
                continue
            points_into_data = any(
                start <= target < start + len(data)
                for start, data in data_segments)
            if target < image_start or target >= image_end:
                if target not in seen_external:
                    seen_external.add(target)
                    external.append((address + offset, target))
            elif points_into_data and target not in seen_internal:
                seen_internal.add(target)
                internal.append((address + offset, target))

    for candidates in (external, internal):
        for slot, target in candidates:
            value = None
            for address, contents in data_segments:
                offset = target - address
                if 0 <= offset and offset + 128 <= len(contents):
                    value = contents[offset:offset + 128]
                    break
            if value is None:
                try:
                    value = remote.read_memory(target, 128)
                except OSError:
                    continue
            if looks_like_boot_args(value):
                return slot
    raise RuntimeError("validated boot_args structure not found")


def find_csr_config(remote: Remote, start: int, size: int) -> int:
    tail = (0x12003109, 0x321D012A, 0x5280022B, 0x6A0B011F,
            0x1A8A0128, 0x6A28001F, 0x1A9F07E0, 0xD65F03C0)

    def match(data: bytes, position: int, pc: int):
        if position + 40 > len(data):
            return None
        instructions = struct.unpack_from("<10I", data, position)
        adrp, load = instructions[:2]
        logical_mask = instructions[2]
        if (logical_mask & 0xFF8003FF != 0x12000109 or
                tuple(instructions[3:]) != tail[1:]):
            return None
        if adrp & 0x9F00001F != 0x90000008:
            return None
        if load & 0xFFC003FF != 0xB9400108:
            return None
        load_value = ((load >> 10) & 0xFFF) * 4
        return decode_adrp(pc, adrp) + load_value

    result = scan_text(remote, start, size, match)
    if result is None:
        raise RuntimeError("csr_check pattern not found")
    return result


def patch_runtime_policy(remote: Remote, pc: int) -> None:
    kernel, segments = find_kernel(remote, pc)
    static_text, _ = segments["__TEXT"]
    static_exec, exec_size = segments["__TEXT_EXEC"]
    slide = kernel - static_text
    live_exec = static_exec + slide
    print(f"kernel: 0x{kernel:x}, slide: 0x{slide:x}")
    # Both platform-expert and CSR initialization live near the front of
    # __TEXT_EXEC on supported macOS kernels. Keep the stopped-boot scan
    # bounded rather than reading the many embedded kexts that follow it.
    patchfinder_size = min(exec_size, 32 * 1024 * 1024)
    try:
        boot_args_pointer = find_boot_args_pointer(remote, live_exec,
                                                    patchfinder_size)
    except RuntimeError:
        boot_args_pointer = find_boot_args_pointer_by_data(remote, segments,
                                                           slide)
    csr_config = find_csr_config(remote, live_exec, patchfinder_size)
    boot_args = int.from_bytes(remote.read_memory(boot_args_pointer, 8),
                               "little")
    command_address = boot_args + 0x6C
    command = remote.read_memory(command_address, 1024).split(b"\0", 1)[0]
    tokens = command.decode("utf-8", "replace").split()
    required = ("-arm64e_preview_abi", "amfi_get_out_of_my_way=1",
                "ipc_control_port_options=0")
    for token in required:
        if token not in tokens:
            tokens.append(token)
    updated = " ".join(tokens).encode("utf-8")
    if len(updated) >= 1024:
        raise RuntimeError("guest boot arguments are full")
    remote.write_memory(command_address, updated + b"\0")
    remote.write_memory(csr_config, struct.pack("<I", 0xFFF))
    print(f"boot_args: 0x{boot_args:x}, csr_config: 0x{csr_config:x}")
    print("command:", updated.decode("utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=12346)
    parser.add_argument("--continue-until-kernel", action="store_true")
    parser.add_argument("--patch-runtime-policy", action="store_true")
    args = parser.parse_args()

    remote = Remote(args.host, args.port)
    try:
        remote.start_no_ack_mode()
        stop_response = b""
        for request in ("qSupported", "?"):
            response = remote.request(request)
            print(f"{request}: {response.decode('ascii', 'replace')}")
            if request == "?":
                stop_response = response
        if args.continue_until_kernel or args.patch_runtime_policy:
            for attempt in range(8):
                fields = {}
                stop_fields = stop_response.decode("ascii").replace(";", ",")
                for field in stop_fields.split(","):
                    if ":" in field:
                        key, value = field.split(":", 1)
                        fields[key] = value
                if "20" not in fields:
                    raise RuntimeError("stop reply did not include the PC")
                pc = int.from_bytes(bytes.fromhex(fields["20"]), "little")
                print(f"stop {attempt}: pc=0x{pc:x}")
                if pc >= 0xffff_0000_0000_0000:
                    break
                remote.socket.settimeout(60)
                stop_response = remote.request("c")
                remote.socket.settimeout(5)
                print("continue:",
                      stop_response.decode("ascii", "replace"))
            else:
                raise RuntimeError("guest did not reach the kernel stop")
            if args.patch_runtime_policy:
                patch_runtime_policy(remote, pc)
    finally:
        remote.close()


if __name__ == "__main__":
    main()
