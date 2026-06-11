# tools/dev_defines.example.sh
#
# Copy this to tools/dev_defines.sh (which is gitignored) and fill in the
# values for your dev backend. tools/seed_demo.sh sources it so the secrets
# never land in git. All values are dev-only.
#
#   cp tools/dev_defines.example.sh tools/dev_defines.sh
#   # then edit tools/dev_defines.sh

# Local LLM shim (tools/claude_shim.py) behind your Tailscale Funnel.
# SHIM_TOKEN is baked into each app build, so a build only works while
# the shim still accepts its token. ROTATING the token strands every
# phone still on the old build — to rotate safely, set the shim's
# SHIM_TOKEN to a comma-separated "<new>,<old>" list (the shim accepts
# any listed token), ship the new build to all testers, then drop the
# old one. The app build itself always bakes a SINGLE token (this one).
export SHIM_URL="https://<your-tailnet-host>.ts.net"
export SHIM_TOKEN="<shim bearer token>"

# Cloudflare Worker forum/sync backend behind the same Funnel (port 8443).
# NOTE (2026-06-11): the app no longer takes FORUM_JWT_SECRET — session
# tokens are minted BY the Worker after Google sign-in. The secret lives
# only on the Worker (`wrangler secret put FORUM_JWT_SECRET`).
export FORUM_API_URL="https://<your-tailnet-host>.ts.net:8443"

# Google Sign-In OAuth client ids.
export GOOGLE_SERVER_CLIENT_ID="<web oauth client id>.apps.googleusercontent.com"
export GOOGLE_IOS_CLIENT_ID="<ios oauth client id>.apps.googleusercontent.com"
