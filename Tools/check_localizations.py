#!/usr/bin/env python3
"""Check app-owned strings and interpolation placeholders in both language resources."""
from pathlib import Path
import json, re, sys
root = Path(__file__).resolve().parent.parent / 'Protracker'
def skip_string(s,i):
    assert s[i]=='"'; i+=1
    while i<len(s):
        if s[i]=='"': return i+1
        if s[i]=='\\':
            if i+1<len(s) and s[i+1]=='(':
                i+=2; depth=1
                while depth:
                    if s[i]=='"': i=skip_string(s,i); continue
                    if s[i]=='(': depth+=1
                    if s[i]==')': depth-=1
                    i+=1
                continue
            i+=2; continue
        i+=1
    raise ValueError('Unclosed string')
def literals(s):
    i=0
    while i<len(s):
        if s[i:i+2]=='//':
            n=s.find('\n',i); i=n if n>=0 else len(s); continue
        if s[i]=='"':
            end=skip_string(s,i); yield i,end,s[i:end]; i=end
        else:i+=1

def key(lit):
    s=lit[1:-1]; out=''; i=0; n=0
    while i<len(s):
        if s[i:i+2]=='\\(':
            out+='{'+str(n)+'}'; n+=1; i+=2; depth=1
            while depth:
                if s[i]=='"':i=skip_string(s,i);continue
                if s[i]=='(':depth+=1
                if s[i]==')':depth-=1
                i+=1
        elif s[i]=='\\':
            out += {'n':'\n','t':'\t','r':'\r','"':'"','\\':'\\','0':'\0'}.get(s[i+1],s[i+1]); i+=2
        else:out+=s[i];i+=1
    return out


catalogs = {}
for language in ['en','de']:
    source = (root / (language+'.lproj') / 'Localizable.strings').read_text()
    pairs = re.findall(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");',source)
    catalogs[language] = {json.loads(k):json.loads(v) for k,v in pairs}
    assert len(pairs) == len(catalogs[language]), 'Duplicate translation key'
assert catalogs['en'].keys() == catalogs['de'].keys(), 'Language keys differ'
required = set()
for path in root.glob('*.swift'):
    if path.name == 'Localization.swift': continue
    source = path.read_text()
    for a,b,literal in literals(source):
        before = source[max(0,a-120):a]
        line = source[source.rfind('\n',0,a)+1:source.find('\n',b) if source.find('\n',b)>=0 else len(source)]
        if (re.search(r'\b(?:L|LK)\(\s*$',before) or
            re.search(r'ModuleError\.invalid\(\s*$',before) or
            re.search(r'(?<![A-Za-z])(?:status|message)\s*(?::[^=]+)?=',line) and path.name in ['TrackerStore.swift','SampleRecorder.swift','MIDIKeyboard.swift','PresetLibrary.swift','TrackerWorkspace.swift']):
            value = key(literal)
            if value and not value.isspace(): required.add(value)
for language,catalog in catalogs.items():
    missing = required-catalog.keys()-{"song",", "}
    assert not missing, f'{language}: missing translations: {sorted(missing)}'
    for key,value in catalog.items():
        assert value, f'{language}: empty translation for {key}'
        assert sorted(re.findall(r'\{[0-9]+\}',key)) == sorted(re.findall(r'\{[0-9]+\}',value)), f'{language}: bad placeholders in {key}'
print(f"Localization coverage: {len(catalogs['en'])} keys in English and German; placeholders match")
