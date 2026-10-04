"""Deterministic, import-free synthetic WASM. No compiler or downloaded input.

This is separate from the immutable qpdf verifier. cpu_chunk executes exactly
262144 xorshift32 rounds. Its result is fed into the next bounded chunk; memory
starts empty and cannot grow beyond 320 MiB. All caller parameters are fixed by
the TypeScript workload; neither export accepts an HTTP-supplied setting.
"""
ITERATIONS = 262144
MAX_PAGES = 5120
SEED = 0x12345678


def uleb(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def sleb(value):
    result = bytearray()
    while True:
        part = value & 127
        value >>= 7
        done = value == 0 and not part & 64 or value == -1 and part & 64
        result.append(part if done else part | 128)
        if done:
            return bytes(result)


def section(kind, raw):
    return bytes([kind]) + uleb(len(raw)) + raw


def name(value):
    raw = value.encode('ascii')
    return uleb(len(raw)) + raw


def module_bytes():
    types = b'\x02\x60\x01\x7f\x01\x7f\x60\x00\x01\x7f'
    functions = b'\x02\x00\x01'
    memory = b'\x01\x01\x00' + uleb(MAX_PAGES)
    exports = (b'\x03' + name('cpu_chunk') + b'\x00\x00' +
               name('chunk_iterations') + b'\x00\x01' + name('memory') + b'\x02\x00')
    # local 0 is the seed/result, local 1 the finite loop counter.
    chunk = (b'\x01\x01\x7f\x03\x40' +
             b'\x20\x00\x20\x00\x41\x0d\x74\x73\x21\x00' +
             b'\x20\x00\x20\x00\x41\x11\x76\x73\x21\x00' +
             b'\x20\x00\x20\x00\x41\x05\x74\x73\x21\x00' +
             b'\x20\x01\x41\x01\x6a\x22\x01\x41' + sleb(ITERATIONS) +
             b'\x49\x0d\x00\x0b\x20\x00\x0b')
    count = b'\x00\x41' + sleb(ITERATIONS) + b'\x0b'
    code = b'\x02' + uleb(len(chunk)) + chunk + uleb(len(count)) + count
    return b'\x00asm\x01\x00\x00\x00' + section(1, types) + section(3, functions) + section(5, memory) + section(7, exports) + section(10, code)


def expected_checksum():
    value = SEED
    for _ in range(ITERATIONS):
        value ^= (value << 13) & 0xffffffff
        value ^= value >> 17
        value ^= (value << 5) & 0xffffffff
    return value
