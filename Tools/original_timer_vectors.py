#!/usr/bin/env python3
"""Execute PT3.61's actual CIA timer programmer ($116D4..$11722).
Unicorn observes register writes; it does not emulate CIA hardware or CPU timing.
"""
import hashlib,json,struct
from pathlib import Path
from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN, UC_HOOK_MEM_WRITE
from unicorn.m68k_const import *
raw=Path('Reference/ProTracker361/Install-Protracker/ProTracker/MAIN/ProTracker_000').read_bytes()
assert hashlib.sha256(raw).hexdigest()=='87789199f121137451b6c49af1af76389b3b1e85d4c78474c3b3d1bdbe80596e'
manifest=json.loads(Path('ReverseEngineering/68000/analysis.json').read_text())

def run(bpm,pal,timer_b,cia):
    u=Uc(UC_ARCH_M68K,UC_MODE_BIG_ENDIAN); u.ctl_set_cpu_model(UC_CPU_M68K_M68000)
    u.mem_map(0,0x100000); u.mem_map(0xbfd000,0x3000)
    for h in manifest['hunks']:
        if h['kind']!='BSS':u.mem_write(h['base'],raw[h['file_offset']:h['file_offset']+h['size']])
    for r in manifest['references']:u.mem_write(r['source'],struct.pack('>I',r['target']))
    def long(a,n):u.mem_write(a,struct.pack('>I',n))
    base=0xbfd000; control=0xf00 if timer_b else 0xe00
    long(0x115b8,0x1b0f87 if pal else 0x1b4f4d); long(0x115b4,int(timer_b)); long(0x11726,base)
    u.mem_write(0x11724,struct.pack('>H',bpm));u.mem_write(0x6eb9c,bytes([int(cia)]));u.mem_write(base+control,b'\x09')
    writes=[]
    def hook(uc,access,address,size,value,data):
        if base<=address<base+0x1000:writes.append({'offset':address-base,'value':value,'size':size})
    u.hook_add(UC_HOOK_MEM_WRITE,hook)
    u.reg_write(UC_M68K_REG_SR,0x2700);u.reg_write(UC_M68K_REG_A7,0xef000);long(0xef000,0xf0000)
    u.emu_start(0x116d4,0xf0000,count=1000)
    assert u.reg_read(UC_M68K_REG_PC)==0xf0000
    lo=0x600 if timer_b else 0x400;hi=lo+0x100
    latch=u.mem_read(base+lo,1)[0] | u.mem_read(base+hi,1)[0]<<8
    return dict(bpm=bpm,pal=pal,timerB=timer_b,cia=cia,latch=latch,writes=writes)
values=[run(bpm,pal,timer_b,cia) for pal in [True,False] for timer_b in [False,True] for cia in [True,False] for bpm in [32,33,40,63,64,80,100,125,127,128,150,175,200,254,255]]
Path('ReverseEngineering/timer-vectors.json').write_text(json.dumps({'sha256':manifest['sha256'],'cases':values},indent=2)+'\n')
print(f'{len(values)} original timer-programmer executions completed')
