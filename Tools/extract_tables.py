#!/usr/bin/env python3
"""Extract numeric replay tables from the supplied PT3.61 68000 binary."""
import hashlib, struct
from pathlib import Path
binary=Path('Reference/ProTracker361/Install-Protracker/ProTracker/MAIN/ProTracker_000').read_bytes()
assert hashlib.sha256(binary).hexdigest() == '87789199f121137451b6c49af1af76389b3b1e85d4c78474c3b3d1bdbe80596e'
def words(address, count): return list(struct.unpack_from('>'+str(count)+'H', binary, 48+address-0x10000))
rows=[words(0x2c172+i*74,37)[:36] for i in range(16)]
text='// Numeric tables recovered from PT3.61 ProTracker_000. See ReverseEngineering/NOTES.md.\nimport Foundation\n\nenum AmigaTables {\n    static let periods: [[Int]] = [\n'
text+='\n'.join('        '+str(row)+',' for row in rows)
text+='\n    ]\n    static let funk: [Int] = '+str(list(binary[48+0x2b5aa-0x10000:48+0x2b5aa-0x10000+16]))+'\n    static let sine: [Int] = '+str(list(binary[48+0x2b5ba-0x10000:48+0x2b5ba-0x10000+32]))+'\n}\n'
Path('Protracker/AmigaTables.swift').write_text(text)
