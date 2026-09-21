#!/usr/bin/env bash
# Push The Pool's auth settings (site URL, redirect URLs, themed sign-in email) to the hosted Supabase project.
# Needs a personal access token from https://supabase.com/dashboard/account/tokens in /root/.supabase_token
# and, for sending as "The Pool", a Resend API key in /root/.resend_key
set -euo pipefail
REF=ephwczmmvbfkbkudehxi
TOKEN=$(tr -d '[:space:]' < /root/.supabase_token)
TPL="$(dirname "$0")/../supabase/templates/magic_link.html"
RESEND_KEY=$(tr -d '[:space:]' < /root/.resend_key 2>/dev/null || true)
RESEND_KEY="$RESEND_KEY" python3 - "$TPL" > /tmp/auth-config.json <<'PY'
import json, os, sys
html = open(sys.argv[1]).read()
subject = "Your sign-in link for The Pool"
cfg = {
  "site_url": "https://thepool.today",
  "uri_allow_list": "https://thepool.today,https://www.thepool.today,https://thepool.today/**,https://www.thepool.today/**",
  "mailer_subjects_magic_link": subject,
  "mailer_templates_magic_link_content": html,
  "mailer_subjects_confirmation": subject,
  "mailer_templates_confirmation_content": html,
}
key = os.environ.get("RESEND_KEY")
if key:
  cfg.update({
    "smtp_host": "smtp.resend.com", "smtp_port": "465", "smtp_user": "resend", "smtp_pass": key,
    "smtp_admin_email": "hello@thepool.today", "smtp_sender_name": "The Pool",
    "rate_limit_email_sent": 100,
  })
print(json.dumps(cfg))
PY
curl -sS -f -X PATCH "https://api.supabase.com/v1/projects/$REF/config/auth" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data @/tmp/auth-config.json -o /dev/null -w "HTTP %{http_code}\n"
rm -f /tmp/auth-config.json
curl -sS -f "https://api.supabase.com/v1/projects/$REF/config/auth" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('site_url:', d['site_url']); print('redirects:', d['uri_allow_list']); print('magic link subject:', d['mailer_subjects_magic_link']); print('smtp sender:', d.get('smtp_sender_name') or '(built-in Supabase email)', d.get('smtp_admin_email') or ''); print('emails/hour:', d.get('rate_limit_email_sent'))"
