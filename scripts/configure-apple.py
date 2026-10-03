#!/usr/bin/env python3
"""Write only public client configuration. Service/provider/signing keys excluded."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
env=dict(line.split('=',1) for line in (ROOT/'.env.staging').read_text().splitlines() if '=' in line)
assert env['SUPABASE_PROJECT_REF']=='coxhjvqpflgxkleydati'
url=env['SUPABASE_URL']; key=env['SUPABASE_ANON_KEY']
assert url=='https://coxhjvqpflgxkleydati.supabase.co'
assert '\n' not in key and '\r' not in key
directory=ROOT/'apps/apple/Config'; directory.mkdir(exist_ok=True)
path=directory/'.env.staging.xcconfig'
# Prevent xcconfig from interpreting the URL's double slash as a comment.
path.write_text('// Generated public client settings; no service credentials.\nSCIENCE_READER_SUPABASE_URL = '+url.replace('://',':/$()/')+'\nSCIENCE_READER_SUPABASE_ANON_KEY = '+key+'\nSCIENCE_READER_ENVIRONMENT = staging\n')
print('Native staging configuration written with public anon key only.')
