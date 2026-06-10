# tools/dev_defines.example.sh
#
# Copy this to tools/dev_defines.sh (which is gitignored) and fill in the
# values for your dev backend. tools/seed_demo.sh sources it so the secrets
# never land in git. All values are dev-only.
#
#   cp tools/dev_defines.example.sh tools/dev_defines.sh
#   # then edit tools/dev_defines.sh

# Local LLM shim (tools/claude_shim.py) behind your Tailscale Funnel.
export SHIM_URL="https://<your-tailnet-host>.ts.net"
export SHIM_TOKEN="<shim bearer token>"

# Cloudflare Worker forum/sync backend behind the same Funnel (port 8443).
export FORUM_API_URL="https://<your-tailnet-host>.ts.net:8443"
export FORUM_JWT_SECRET="<forum jwt shared secret>"

# Google Sign-In OAuth client ids.
export GOOGLE_SERVER_CLIENT_ID="<web oauth client id>.apps.googleusercontent.com"
export GOOGLE_IOS_CLIENT_ID="<ios oauth client id>.apps.googleusercontent.com"
