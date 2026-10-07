#!/usr/bin/env python3
"""Point staging Supabase Auth email (sign-in codes) at Resend SMTP; invite-only.

Reads SMTP_* and RESEND_API_KEY from .env.providers (local, ignored). Without a
verified Resend domain the sender is onboarding@resend.dev, which only delivers
to the Resend account owner's address. Prints only non-secret readback fields.
"""
import json
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'coxhjvqpflgxkleydati'

def dotenv(path):
    values = {}
    for line in path.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.split('=', 1); values[k.strip()] = v.strip().strip('"').strip("'")
    return values

providers = dotenv(ROOT / '.env.providers')
token = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'], capture_output=True, text=True, check=True).stdout.strip()
desired = {
    'external_email_enabled': True,
    'disable_signup': True,  # invite-only beta
    'smtp_host': providers.get('SMTP_HOST', 'smtp.resend.com'),
    'smtp_port': providers.get('SMTP_PORT', '465'),
    'smtp_user': providers.get('SMTP_USER', 'resend'),
    'smtp_pass': providers['RESEND_API_KEY'],
    'smtp_admin_email': providers.get('SMTP_FROM', 'onboarding@resend.dev'),
    'smtp_sender_name': providers.get('SMTP_SENDER_NAME', 'Gradstep'),
    'rate_limit_email_sent': 30,  # per hour; Resend's free tier allows 100/day
}
url = f'https://api.supabase.com/v1/projects/{PROJECT}/config/auth'
headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}
request = urllib.request.Request(url, data=json.dumps(desired).encode(), headers=headers, method='PATCH')
with urllib.request.urlopen(request, timeout=60) as response:
    response.read()
with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
    config = json.loads(response.read())
shown = ['external_email_enabled', 'disable_signup', 'smtp_host', 'smtp_port', 'smtp_user', 'smtp_admin_email', 'smtp_sender_name',
         'mailer_otp_length', 'mailer_otp_exp', 'rate_limit_email_sent']
print(json.dumps({k: config.get(k) for k in shown}, indent=1))
print('smtp_pass set:', bool(config.get('smtp_pass')))
