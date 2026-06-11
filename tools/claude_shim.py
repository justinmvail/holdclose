#!/usr/bin/env python3
"""Local HTTP shim that wraps `claude --print` for the Careblazers
dev-mode LLM provider.

Listens on http://localhost:8765/generate. Accepts POST JSON of shape:
  {"system": "...", "user": "..."}
Returns Server-Sent Events (SSE) streaming the model's response.

Usage:
  python3 tools/claude_shim.py
"""

import base64
import hmac
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Listen port; overridable so a second instance (tests, a staging copy)
# can run beside the live one.
PORT = int(os.environ.get("SHIM_PORT", "8765"))

# Per-route request-body ceilings (bytes). Content-Length is
# attacker-controlled on a Funnel-exposed endpoint — without a cap one
# request could balloon memory (and /feedback writes to disk). Prompts
# run a few tens of KB; feedback carries a base64 phone screenshot.
MAX_GENERATE_BYTES = 256 * 1024
MAX_FEEDBACK_BYTES = 6 * 1024 * 1024
MAX_PHONEMIZE_BYTES = 64 * 1024

# Hard wall-clock ceiling on one `claude` invocation. A hung CLI (auth
# prompt, network stall) otherwise pins a worker thread + child process
# forever — ThreadingHTTPServer threads are unbounded, so repeated hangs
# leak both. Generous: a long streamed reply finishes well inside it.
GENERATE_TIMEOUT_SECONDS = int(os.environ.get("SHIM_GENERATE_TIMEOUT", "180"))
# Where alpha-tester bug reports land (POST /feedback). One <id>.json +
# optional <id>.png per report, plus a rolling feedback.jsonl. Relative to
# the shim's CWD (the project dir) by default; override with FEEDBACK_DIR.
FEEDBACK_DIR = os.environ.get("FEEDBACK_DIR", "feedback")
# Bind 127.0.0.1 by default (local dev). Set SHIM_HOST=0.0.0.0 to accept
# connections from other machines (e.g. a No-IP host this Mac forwards to).
# Only expose it behind SHIM_TOKEN + your router/firewall.
HOST = os.environ.get("SHIM_HOST", "127.0.0.1")
# Shared secret. When set, every request must carry
# `Authorization: Bearer <SHIM_TOKEN>` (the app sends it via
# --dart-define=SHIM_TOKEN=...). Empty = open (fine for localhost only).
#
# Comma-separated = a ROTATION GRACE WINDOW: the shim accepts ANY listed
# token. Because the token is baked into each app build, rotating it
# would otherwise 401 every phone still on the old build the instant the
# shim restarts (exactly the outage seen 2026-06-11). To rotate safely:
# set `SHIM_TOKEN=<new>,<old>`, ship the new build to every tester, then
# drop `<old>` once they've all updated. Whitespace around entries is
# trimmed; empty entries are ignored.
SHIM_TOKENS = [
    t.strip() for t in os.environ.get("SHIM_TOKEN", "").split(",") if t.strip()
]
CLAUDE_CMD = "claude"
# Neutral, EMPTY working dir for the one-shot chat calls. Running `claude`
# in the project dir made every chat reply load this repo's CLAUDE.md
# (~10k tokens) and scan the tree before answering — pure waste for a chat
# completion. An empty cwd drops all of it. Created once at startup.
CHAT_CWD = tempfile.mkdtemp(prefix="careblazers-shim-chat-")


class Handler(BaseHTTPRequestHandler):
    def _bad(self, code, msg):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode())

    def _authorized(self):
        # Open when no token is configured; otherwise the bearer must
        # match ANY configured token (the rotation grace window).
        if not SHIM_TOKENS:
            return True
        supplied = self.headers.get("Authorization") or ""
        # Constant-time compare against EVERY candidate — and never
        # short-circuit on a match, so the number of comparisons (and
        # thus timing) doesn't leak which/whether a token matched.
        ok = False
        for token in SHIM_TOKENS:
            if hmac.compare_digest(supplied, f"Bearer {token}"):
                ok = True
        return ok

    def _read_body(self, max_bytes):
        """Read the request body, bounded by [max_bytes].

        Returns the bytes, or None after answering 413/400 — the
        declared Content-Length is client-controlled and must never be
        trusted as a read size on a publicly-reachable endpoint.
        """
        try:
            length = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            self._bad(400, "bad request: invalid Content-Length")
            return None
        if length < 0 or length > max_bytes:
            self._bad(413, "request body too large")
            return None
        return self.rfile.read(length)

    def do_POST(self):
        if not self._authorized():
            return self._bad(401, "unauthorized")
        if self.path == "/feedback":
            return self._feedback()
        if self.path == "/phonemize":
            return self._phonemize()
        if self.path != "/generate":
            return self._bad(404, "Not Found")
        body = self._read_body(MAX_GENERATE_BYTES)
        if body is None:
            return
        try:
            payload = json.loads(body)
            system = payload["system"]
            user = payload["user"]
            # Opt-in token streaming. Only the chat endpoint sets this; the
            # decoder + recap leave it off because their parsers accumulate a
            # single final message (partial chunks would corrupt their JSON /
            # double the text). See --include-partial-messages below.
            partial = bool(payload.get("partial"))
        except Exception as exc:
            return self._bad(400, f"bad request: {exc}")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        # Lean one-shot invocation. This is a chat completion, NOT an agent
        # session, so we strip everything the agent harness loads by default:
        #   --system-prompt (REPLACE, not append) → drops Claude Code's own
        #     multi-thousand-token agent prompt; the app's coaching prompt
        #     becomes the entire system prompt.
        #   --tools (empty: the next token is a flag) → no tool definitions
        #     loaded into context, no tool setup.
        #   --strict-mcp-config --mcp-config {} → no MCP servers start.
        #   --exclude-dynamic-system-prompt-sections → drop cwd/env/git/memory
        #     blurbs (only valid with --system-prompt).
        #   cwd=CHAT_CWD (empty dir) → no CLAUDE.md, no repo scan.
        # Together these cut per-reply input from ~15-20k tokens to just the
        # coaching prompt + the turn, which is the difference between ~15s
        # and a couple of seconds to first token.
        cmd = [
            CLAUDE_CMD, "--print", "--verbose", "--output-format", "stream-json",
            # --effort low: a warm coaching reply doesn't need extended
            #   reasoning; higher effort spends seconds on a thinking block
            #   BEFORE the first visible word. Low gets the answer streaming
            #   sooner. (--bare would also skip hooks/LSP but it disables the
            #   OAuth/keychain read → authentication_failed, so it's out.)
            "--effort", "low",
            "--model", "claude-sonnet-4-6",
            "--system-prompt", system,
            "--tools",
            "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--exclude-dynamic-system-prompt-sections",
            # No skills in a chat completion — skip resolving them.
            "--disable-slash-commands",
        ]
        if partial:
            # Stream token chunks as they generate (chat only). WITHOUT this,
            # stream-json only emits the assistant message once it's COMPLETE
            # — the app showed nothing for ~16s, then the whole reply at once.
            # With it, words appear in a few seconds and stream in continuously
            # (as `stream_event`/`content_block_delta`/`text_delta` events).
            cmd.append("--include-partial-messages")
        cmd.append(user)
        try:
            # MAX_THINKING_TOKENS=0 disables the extended-thinking block the
            # model otherwise emits BEFORE its answer — seconds of latency
            # before the first visible word, for a reply that doesn't need it.
            env = {**os.environ, "MAX_THINKING_TOKENS": "0"}
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, bufsize=1, cwd=CHAT_CWD, env=env,
            )

            # Drain stderr CONCURRENTLY. Reading it only after stdout
            # closes deadlocks when the CLI fills the ~64KB stderr pipe
            # while we're blocked on stdout (and vice versa).
            stderr_lines = []

            def _drain_stderr():
                try:
                    for err_line in proc.stderr:
                        stderr_lines.append(err_line)
                except Exception:
                    pass

            stderr_thread = threading.Thread(target=_drain_stderr, daemon=True)
            stderr_thread.start()

            # Watchdog: a hung `claude` (auth prompt, network stall) must
            # not pin this worker thread + child forever. The kill makes
            # the stdout iterator below terminate.
            timed_out = threading.Event()

            def _kill_on_timeout():
                timed_out.set()
                try:
                    proc.kill()
                except Exception:
                    pass

            watchdog = threading.Timer(GENERATE_TIMEOUT_SECONDS, _kill_on_timeout)
            watchdog.daemon = True
            watchdog.start()
            try:
                for line in proc.stdout:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    self.wfile.write(f"data: {line}\n\n".encode())
                    self.wfile.flush()
                proc.wait()
            finally:
                watchdog.cancel()
                stderr_thread.join(timeout=5)
            if timed_out.is_set():
                self.wfile.write(
                    f"data: {json.dumps({'error': 'the reply timed out'})}\n\n".encode()
                )
            elif proc.returncode != 0:
                # The raw stderr can carry local paths / auth detail —
                # log it server-side, hand the client a generic line.
                sys.stderr.write(
                    "[shim] claude exited %s: %s\n"
                    % (proc.returncode, "".join(stderr_lines).strip()[:2000])
                )
                self.wfile.write(
                    f"data: {json.dumps({'error': 'the coach backend hit an error'})}\n\n".encode()
                )
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except FileNotFoundError:
            self.wfile.write(
                f"data: {json.dumps({'error': 'claude binary not found on PATH'})}\n\n".encode()
            )
        except Exception as exc:
            sys.stderr.write(f"[shim] generate failed: {exc}\n")
            self.wfile.write(
                f"data: {json.dumps({'error': 'the coach backend hit an error'})}\n\n".encode()
            )

    def _feedback(self):
        """POST /feedback — store one alpha-tester bug report.

        Accepts the report JSON the app's FeedbackSender posts, with an
        optional base64 `screenshot_base64`. Writes:
          - FEEDBACK_DIR/<id>.png      (the screenshot, if present)
          - FEEDBACK_DIR/<id>.json     (the report metadata)
          - FEEDBACK_DIR/feedback.jsonl (one line appended per report)
        Returns 200 {"stored": "<id>"}. No `claude` call — pure storage.
        """
        body = self._read_body(MAX_FEEDBACK_BYTES)
        if body is None:
            return
        try:
            payload = json.loads(body)
        except Exception as exc:
            return self._bad(400, f"bad request: {exc}")

        # Sanitize the id to a safe filename (no path traversal).
        raw_id = str(payload.get("id") or "")
        safe_id = "".join(
            c for c in raw_id if c.isalnum() or c in "_-"
        ) or f"fb_{int(time.time() * 1000)}"

        os.makedirs(FEEDBACK_DIR, exist_ok=True)

        shot_b64 = payload.pop("screenshot_base64", None)
        screenshot_file = None
        if shot_b64:
            try:
                png = base64.b64decode(shot_b64)
                screenshot_file = f"{safe_id}.png"
                with open(os.path.join(FEEDBACK_DIR, screenshot_file), "wb") as fh:
                    fh.write(png)
            except Exception:
                screenshot_file = None

        payload["screenshot_file"] = screenshot_file

        # On-device log snapshot → a sidecar .log file (and drop the bulky
        # text out of the .json so the metadata stays readable).
        logs = payload.pop("logs", None)
        logs_file = None
        if logs:
            try:
                logs_file = f"{safe_id}.log"
                with open(os.path.join(FEEDBACK_DIR, logs_file), "w") as fh:
                    fh.write(logs)
            except Exception:
                logs_file = None
        payload["logs_file"] = logs_file

        payload["received_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")

        try:
            with open(os.path.join(FEEDBACK_DIR, f"{safe_id}.json"), "w") as fh:
                json.dump(payload, fh, indent=2)
            with open(os.path.join(FEEDBACK_DIR, "feedback.jsonl"), "a") as fh:
                fh.write(json.dumps(payload) + "\n")
        except Exception as exc:
            return self._bad(500, f"store failed: {exc}")

        out = json.dumps({"stored": safe_id}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
        sys.stderr.write(
            f"[shim] stored feedback {safe_id} "
            f"({payload.get('category')}) from {payload.get('tester_name')!r}\n"
        )

    def _phonemize(self):
        """POST /phonemize {"text": "...", "voice": "en-us"} → 200
        {"phonemes": ["h","ə","l","ˈ","o","ʊ",...]}

        Pitch-week interim for the careblazers BundledTTSProvider on iOS
        — Phase 9.3's Swift `EspeakNGPhonemizer` falls back to a
        character-by-character lookup that produces gibberish audio,
        and bundling espeak-ng on-device (the production fix) is
        queued as Phase 10 in TASKS.md. This endpoint lets the Swift
        side defer text-to-IPA to Piper's Python `piper_phonemize`
        package (which embeds espeak-ng) while the demo needs to
        sound right NOW.

        Caller passes raw English text; we return the IPA phoneme
        sequence. The app maps each phoneme through the per-voice
        `phoneme_id_map` from `<voice>.onnx.json` to produce the
        int64 IDs the model wants — that mapping stays on the Swift
        side so the shim doesn't need any voice-specific knowledge.

        Phonemizer is imported lazily so an operator running the shim
        purely for the /generate endpoint isn't penalized by the
        ~20 MB native lib load.
        """
        body = self._read_body(MAX_PHONEMIZE_BYTES)
        if body is None:
            return
        try:
            payload = json.loads(body)
            text = payload["text"]
            voice = payload.get("voice", "en-us")
            # Pause tuning — caller can override per-utterance.
            # CRUCIAL: the `_` (pad) phoneme is VOCALIZED in Piper —
            # repeating it makes the voice say "uhhh" between words.
            # Real silence comes from the punctuation phonemes
            # themselves; we extend pauses by REPEATING the `,` and
            # `.` tokens, which the model interprets as a longer
            # silent beat instead of a vocal filler. Defaults are
            # 1-extra-comma (~150 ms) and 2-extra-periods (~500 ms).
            comma_pause = int(payload.get("comma_pause", 1))
            period_pause = int(payload.get("period_pause", 2))
        except Exception as exc:
            return self._bad(400, f"bad request: {exc}")
        try:
            from piper_phonemize import phonemize_espeak
        except ImportError:
            return self._bad(
                501,
                "piper_phonemize not installed — run `pip3 install "
                "piper-phonemize` (the careblazers BundledTTSProvider "
                "needs this for the iOS demo until Phase 10 lands "
                "espeak-ng on-device)",
            )
        try:
            sentences = phonemize_espeak(text, voice)
        except Exception as exc:
            return self._bad(500, f"phonemize failed: {exc}")
        flat = []
        for i, sentence in enumerate(sentences):
            if i > 0:
                # Inter-sentence boundary. Repeat the period token so
                # the coach takes a real silent beat (NOT a vocalized
                # pad) before the next thought.
                flat.extend(["."] * period_pause)
            for phoneme in sentence:
                flat.append(phoneme)
                if phoneme == ",":
                    flat.extend([","] * comma_pause)
                elif phoneme == ".":
                    flat.extend(["."] * period_pause)
        out = json.dumps({"phonemes": flat}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, fmt, *args):
        # quieter default logging
        sys.stderr.write("[shim] " + fmt % args + "\n")


def main():
    print(f"[shim] Careblazers LLM shim listening on http://{HOST}:{PORT}")
    print(f"[shim] Uses local `{CLAUDE_CMD}` binary (your Claude Max subscription).")
    if SHIM_TOKENS:
        print(f"[shim] Accepting {len(SHIM_TOKENS)} bearer token(s).")
    if not SHIM_TOKENS:
        # Unconditional — a Tailscale Funnel forwards PUBLIC traffic to
        # 127.0.0.1, so "bound locally" is NOT "reachable locally only".
        # A tokenless shim behind a funnel is an open door to your
        # subscription and the feedback store.
        print(
            "[shim] WARNING: SHIM_TOKEN is not set — every endpoint is OPEN. "
            "That is fine for purely-local dev, but a Tailscale Funnel (or "
            "any port forward) reaches this process even on 127.0.0.1. "
            "Set SHIM_TOKEN before exposing it.",
            file=sys.stderr,
        )
    # Threaded so a couple of testers don't fully serialize behind one
    # in-flight `claude` call.
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
