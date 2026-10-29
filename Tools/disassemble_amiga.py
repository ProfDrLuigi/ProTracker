#!/usr/bin/env python3
"""Inspect Amiga LoadSeg HUNK executables; relocate and disassemble MC68000 code.
Requires capstone 5.x. No emulation, execution, or original binary modification.
Addresses in reports are synthetic load addresses, NOT offsets in the .lha.
"""
import argparse, hashlib, json, re, struct
from pathlib import Path
from capstone import Cs, CS_ARCH_M68K, CS_MODE_BIG_ENDIAN, CS_MODE_M68K_000, CS_MODE_M68K_030

NAMES = {1001:'CODE',1002:'DATA',1003:'BSS'}

def inspect(path, output, cpu="68000"):
    raw = path.read_bytes()
    pos = 0
    def u32():
        nonlocal pos
        if pos + 4 > len(raw): raise ValueError(f'Truncated HUNK at {pos:x}')
        value = struct.unpack_from('>I', raw, pos)[0]; pos += 4
        return value
    def skip_names():
        nonlocal pos
        while True:
            size = u32()
            if size == 0: break
            pos += size * 4
    assert u32() == 1011, 'Not an Amiga HUNK_HEADER executable'
    skip_names()
    table, first, last = u32(), u32(), u32()
    allocations = []
    for _ in range(last - first + 1):
        size = u32()
        if size & 0xc0000000 == 0xc0000000: u32()
        allocations.append((size & 0x3fffffff) * 4)
    hunks = []
    while pos < len(raw):
        record = u32() & 0x3fffffff
        if record in NAMES:
            size = u32() * 4
            start = pos
            data = bytearray(raw[pos:pos+size]) if record != 1003 else bytearray(size)
            if record != 1003: pos += size
            hunks.append(dict(index=len(hunks), kind=NAMES[record], file_offset=start,
                              size=size, data=data, relocations=[]))
        elif record == 1004:  # HUNK_RELOC32
            while True:
                count = u32()
                if not count: break
                target = u32()
                for _ in range(count): hunks[-1]['relocations'].append((u32(), target))
        elif record == 1008:  # HUNK_SYMBOL
            while True:
                size = u32()
                if not size: break
                pos += size * 4; u32()
        elif record in (1000, 1009): pos += u32() * 4
        elif record == 1010: pass
        else: raise ValueError(f'Unsupported HUNK {record} at {pos-4:x}')
    address = 0x10000
    for hunk in hunks:
        hunk['base'] = address
        address += (max(hunk['size'], allocations[hunk['index']]) + 4095) & ~4095
    references = []
    for hunk in hunks:
        for offset, target in hunk['relocations']:
            original = struct.unpack_from('>I', hunk['data'], offset)[0]
            resolved = original + hunks[target-first]['base']
            struct.pack_into('>I', hunk['data'], offset, resolved)
            references.append(dict(source=hunk['base']+offset, target=resolved,
                                   target_hunk=target, target_offset=original))
    strings = []
    for hunk in hunks:
        if hunk['kind'] == 'BSS': continue
        for m in re.finditer(rb'[\x20-\x7e]{5,}', hunk['data']):
            value = m.group().decode('ascii')
            if re.search('[a-zA-Z]{3}', value):
                addr = hunk['base']+m.start()
                refs = [r['source'] for r in references if addr <= r['target'] < addr+len(value)]
                strings.append(dict(address=addr, file_offset=hunk['file_offset']+m.start(),
                                    value=value, references=refs))
    output.mkdir(parents=True, exist_ok=True)
    dis = Cs(CS_ARCH_M68K, CS_MODE_BIG_ENDIAN | (CS_MODE_M68K_030 if cpu == "68030" else CS_MODE_M68K_000))
    dis.skipdata = True
    hardware = []
    for hunk in hunks:
        if hunk['kind'] != 'CODE': continue
        rows = [f'; {path.name}, HUNK {hunk["index"]}, load ${hunk["base"]:08x}',
                '; Linear sweep: embedded data can decode as instructions. Validate control flow.']
        for ins in dis.disasm(bytes(hunk['data']), hunk['base']):
            rows.append(f'{ins.address:08x}  {ins.bytes.hex():24} {ins.mnemonic:12} {ins.op_str}')
            if any(x in ins.op_str.lower() for x in ('$dff', '$bfe', '$bfd')):
                hardware.append(dict(address=ins.address, instruction=f'{ins.mnemonic} {ins.op_str}'))
        (output/f'hunk-{hunk["index"]}.s').write_text('\n'.join(rows)+'\n')
    manifest = dict(binary=str(path), sha256=hashlib.sha256(raw).hexdigest(),
                    size=len(raw), address_convention='Synthetic bases starting at 0x10000; relocated HUNK_RELOC32',
                    hunks=[{k:v for k,v in h.items() if k not in ('data','relocations')} |
                           dict(relocation_count=len(h['relocations'])) for h in hunks],
                    references=references, strings=strings, hardware_accesses=hardware)
    (output/'analysis.json').write_text(json.dumps(manifest, indent=2))
    (output/'strings.tsv').write_text('\n'.join(f'{s["address"]:08x}\t{s["file_offset"]:08x}\t'+
            ','.join(f'{v:08x}' for v in s['references'])+'\t'+s['value'] for s in strings)+'\n')
    print(json.dumps({k:v for k,v in manifest.items() if k not in ('strings','references','hardware_accesses')}, indent=2))
    print(f'{len(references)} relocations; {len(strings)} strings; {len(hardware)} hardware instructions')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path); parser.add_argument('output', type=Path)
    parser.add_argument('--cpu', choices=['68000','68030'], default='68000')
    args = parser.parse_args(); inspect(args.binary, args.output, args.cpu)
