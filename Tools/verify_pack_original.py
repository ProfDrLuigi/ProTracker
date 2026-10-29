#!/usr/bin/env python3
"""Verify a Swift-written PACK file by running PT3.61's actual $23B8A decoder."""
import hashlib, json, struct, sys
from pathlib import Path
from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN
from unicorn.m68k_const import *
root = Path(__file__).resolve().parent.parent
raw = (root/'Reference/ProTracker361/Install-Protracker/ProTracker/MAIN/ProTracker_000').read_bytes()
assert hashlib.sha256(raw).hexdigest() == '87789199f121137451b6c49af1af76389b3b1e85d4c78474c3b3d1bdbe80596e'
manifest = json.loads((root/'ReverseEngineering/68000/analysis.json').read_text())
packed = Path(sys.argv[1]).read_bytes(); expected = Path(sys.argv[2]).read_bytes()
assert packed[:4] in (b'PACK',b'PAKK')
length, size = struct.unpack_from('>II', packed, 4)
assert size == len(expected) and len(packed) >= length+12 and size < 0x400000
uc = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
uc.ctl_set_cpu_model(UC_CPU_M68K_M68000); uc.mem_map(0,0x1000000)
for h in manifest['hunks']:
    if h['kind'] != 'BSS': uc.mem_write(h['base'],raw[h['file_offset']:h['file_offset']+h['size']])
for ref in manifest['references']: uc.mem_write(ref['source'],struct.pack('>I',ref['target']))
source, target, stack, done = 0x100000,0x500000,0xef000,0xf0000
uc.mem_write(source,packed[12:12+length]); uc.mem_write(stack,struct.pack('>I',done))
uc.reg_write(UC_M68K_REG_SR,0x2700); uc.reg_write(UC_M68K_REG_A7,stack)
uc.reg_write(UC_M68K_REG_A0,source); uc.reg_write(UC_M68K_REG_A1,target)
uc.reg_write(UC_M68K_REG_D0,length); uc.reg_write(UC_M68K_REG_D1,size)
uc.emu_start(0x23b8a,done,count=10_000_000)
assert uc.reg_read(UC_M68K_REG_PC) == done, 'Original decoder did not return'
actual = bytes(uc.mem_read(target,size))
assert actual == expected, 'Original decoder produced different bytes'
print(f'PASS: actual PT3.61 68000 decoder reproduced all {size} bytes of the Swift PACK export')
