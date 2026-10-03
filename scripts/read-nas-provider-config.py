#!/usr/bin/env python3
"""Read the one authorized NAS project file; write only the local secret file.

No remote writes, directory exploration, shell evaluation of dotenv contents, or
provider calls. Refuse a symlink for the target file or nested project directory.
"""
import os
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
source='/volume1/@home/selfhost/science-reader/.env.local'
command="test ! -L /volume1/@home/selfhost/science-reader && test ! -L "+source+" && test -f "+source+" && cat "+source
result=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10','Ben@192.168.1.203',command],capture_output=True,text=True,timeout=30)
if result.returncode:
    raise SystemExit('Authorized provider configuration could not be read; no other NAS paths were accessed.')

def dotenv(text):
    values={}
    for line in text.splitlines():
        line=line.strip()
        if not line or line.startswith('#') or '=' not in line: continue
        name,value=line.split('=',1); name=name.removeprefix('export ').strip();value=value.strip()
        if len(value)>1 and value[0]==value[-1] and value[0] in ('"',"'"): value=value[1:-1]
        values[name]=value
    return values

values=dotenv(result.stdout)
allowed=['MATHPIX_APP_ID','MATHPIX_APP_KEY','ANTHROPIC_API_KEY','TAVILY_API_KEY','DEEPSEEK_API_KEY']
selected={name:values[name] for name in allowed if values.get(name)}
reference=dotenv((ROOT.parent/'textbrain/.env').read_text())
shared=[name for name,value in selected.items() if reference.get(name)==value]
if shared:
    # Preserve the boundary with TextBrain even when the NAS happened to reuse a
    # credential. Report names only; these credentials will not be deployed.
    for name in shared: del selected[name]
    print('Excluded credentials also used by TextBrain:',', '.join(shared))
target=ROOT/'.env.providers'
if target.exists(): raise SystemExit('Local provider configuration already exists; refusing to replace it.')
fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as output:
    for name,value in selected.items():
        if '\n' in value or '\r' in value: raise RuntimeError('Invalid credential encoding')
        output.write(name+'='+value+'\n')
print('Copied provider variable names:',', '.join(selected) if selected else '(none)')
print('Credentials are local only. No paid provider requests or NAS writes were made.')
