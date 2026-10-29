#!/usr/bin/env python3
"""Run *isolated* replay routines from the supplied Amiga executable in Unicorn.
No AmigaOS calls or original GUI are executed. Produces a differential oracle
for the native Swift tests, grounded in the actual relocated 68000 machine code.
"""
import hashlib, json, struct
from pathlib import Path
from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN
from unicorn.m68k_const import *

SOURCE=Path('Reference/ProTracker361/Install-Protracker/ProTracker/MAIN/ProTracker_000')
raw=SOURCE.read_bytes()
assert hashlib.sha256(raw).hexdigest()=='87789199f121137451b6c49af1af76389b3b1e85d4c78474c3b3d1bdbe80596e'
manifest=json.loads(Path('ReverseEngineering/68000/analysis.json').read_text())
STATE=0x62d84; AUDIO=0xdff0a0; RETURN=0xf0000; STACK=0xef000

def execute(effect,parameter,period=428,volume=32,tick=1,**params):
    uc=Uc(UC_ARCH_M68K,UC_MODE_BIG_ENDIAN)
    uc.ctl_set_cpu_model(UC_CPU_M68K_M68000)
    uc.mem_map(0,0x100000); uc.mem_map(0xdff000,0x1000); uc.mem_map(0xbfd000,0x3000)
    for h in manifest['hunks']:
        if h['kind']!='BSS': uc.mem_write(h['base'],raw[h['file_offset']:h['file_offset']+h['size']])
    for ref in manifest['references']: uc.mem_write(ref['source'],struct.pack('>I',ref['target']))
    def byte(a,v): uc.mem_write(a,bytes([v&255]))
    def word(a,v): uc.mem_write(a,struct.pack('>H',v&65535))
    def long(a,v): uc.mem_write(a,struct.pack('>I',v))
    byte(STATE+2,effect); byte(STATE+3,parameter)
    word(STATE+16,period); byte(STATE+19,volume); word(STATE+20,64)
    byte(STATE+18,params.get('finetune',0)); word(STATE+24,params.get('target',0))
    byte(STATE+22,params.get('direction',0)); byte(STATE+23,params.get('portaSpeed',0))
    byte(STATE+26,params.get('vibrato',0)); byte(STATE+27,params.get('phase',0))
    byte(STATE+28,params.get('tremolo',0)); byte(STATE+29,params.get('tremoloPhase',0))
    byte(STATE+30,params.get('wave',0)); byte(STATE+31,params.get('glissando',0))
    byte(0x2cace,255); word(0x2c9e4,64); long(0x2b330,tick)
    if params.get('sampleFixture'):
        pcm=bytes([10,30,176,60,216,100,246,20])
        uc.mem_write(0x90000,pcm)
        long(STATE+4,0x90000); word(STATE+8,4)
        long(STATE+10,0x90000); word(STATE+14,4)
        long(STATE+0x24,0x90000)
    # Seed output registers as the native renderer does before dispatch.
    word(AUDIO+6,period); word(AUDIO+8,volume)
    uc.reg_write(UC_M68K_REG_SR,0x2700)
    uc.reg_write(UC_M68K_REG_A5,AUDIO); uc.reg_write(UC_M68K_REG_A6,STATE)
    uc.reg_write(UC_M68K_REG_A7,STACK); long(STACK,RETURN)
    # Full dispatcher for nonzero ticks; row-zero effects use the original row dispatcher.
    uc.mem_write(0xe0000, bytes.fromhex("4eb90002a6344eb900029bf04e75"))
    entry=0x2a118 if tick else 0xe0000
    try: uc.emu_start(entry,RETURN,count=10000)
    except Exception as error: raise RuntimeError(f"{effect:x}/{parameter:02x} failed at {uc.reg_read(UC_M68K_REG_PC):x}") from error
    if uc.reg_read(UC_M68K_REG_PC)!=RETURN: raise RuntimeError('Routine failed to return')
    def readword(a): return struct.unpack('>H',bytes(uc.mem_read(a,2)))[0]
    def readbyte(a): return uc.mem_read(a,1)[0]
    result = dict(period=readword(STATE+16),volume=readbyte(STATE+19),
                outputPeriod=readword(AUDIO+6),outputVolume=readword(AUDIO+8),
                target=readword(STATE+24),phase=readbyte(STATE+27),
                tremoloPhase=readbyte(STATE+29))
    if params.get('sampleFixture'):
        for i,value in enumerate(uc.mem_read(0x90000,8)):
            result[f'pcm{i}']=value if value<128 else value-256
    return result

cases=[]
def add(name,**data): cases.append(dict(name=name,input=data,expected=execute(**data)))
for amount in (0,1,15,63,255):
    for period in (0,113,120,428,850,856):
        add(f'1xx slide up {period}/{amount}',effect=1,parameter=amount,period=period)
        add(f'2xx slide down {period}/{amount}',effect=2,parameter=amount,period=period)
for value in (0,1,15,16,31,240,255):
    for volume in (0,1,32,63,64): add(f'Axy volume {volume}/{value}',effect=10,parameter=value,volume=volume)
for value in (0,32,64,65,255): add(f'Cxx clamp {value}',effect=12,parameter=value,tick=0)
for tick in (1,2,3,4,5):
    for fine in (0,3,8,15): add(f'0xy arpeggio {tick}/{fine}',effect=0,parameter=0x37,tick=tick,finetune=fine)
for value in (0,0x12,0x47,0x8f):
    for phase in (0,16,64,128,192):
        add(f'4xy vibrato {value}/{phase}',effect=4,parameter=value,phase=phase,vibrato=0x23)
        add(f'7xy tremolo {value}/{phase}',effect=7,parameter=value,tremoloPhase=phase,tremolo=0x23)
for target in (214,428,856):
    for period in (214,428,856):
        if period!=target: add(f'3xx porta {period}/{target}',effect=3,parameter=8,period=period,target=target,direction=int(period>target))
for command in (0x11,0x1f,0x21,0x2f,0xa1,0xaf,0xb1,0xbf,0xc0):
    add(f'Exy tick0 {command:x}',effect=14,parameter=command,tick=0)
for shape in (1,2,3):
    for phase in (0,64,128,192):
        add(f'4xy waveform {shape}/{phase}',effect=4,parameter=0x47,phase=phase,wave=shape)
        add(f'7xy waveform {shape}/{phase}',effect=7,parameter=0x47,tremoloPhase=phase,wave=shape<<4)
for tick in (0,1,3):
    add(f'E8 Karplus Strong tick {tick}',effect=14,parameter=0x80,tick=tick,sampleFixture=1)
for speed in (0,1,8,15):
    add(f'EF invert loop start {speed}',effect=14,parameter=0xf0+speed,tick=0,sampleFixture=1)
output=Path('ReverseEngineering/replay-vectors.json')
output.write_text(json.dumps(dict(binary_sha256=manifest['sha256'],cases=cases),indent=2)+'\n')
print(f'{len(cases)} isolated original-binary executions completed; wrote {output}')
