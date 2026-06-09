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
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8765
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
SHIM_TOKEN = os.environ.get("SHIM_TOKEN", "")
CLAUDE_CMD = "claude"


class Handler(BaseHTTPRequestHandler):
    def _bad(self, code, msg):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode())

    def _authorized(self):
        # Open when no token is configured; otherwise require the bearer.
        if not SHIM_TOKEN:
            return True
        return self.headers.get("Authorization") == f"Bearer {SHIM_TOKEN}"

    def do_POST(self):
        if not self._authorized():
            return self._bad(401, "unauthorized")
        if self.path == "/feedback":
            return self._feedback()
        if self.path == "/phonemize":
            return self._phonemize()
        if self.path != "/generate":
            return self._bad(404, "Not Found")
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
            system = payload["system"]
            user = payload["user"]
        except Exception as exc:
            return self._bad(400, f"bad request: {exc}")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        cmd = [
            CLAUDE_CMD, "--print", "--verbose", "--output-format", "stream-json",
            "--model", "claude-sonnet-4-6",
            "--append-system-prompt", system,
            user,
        ]
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, bufsize=1,
            )
            for line in proc.stdout:
                line = line.rstrip("\n")
                if not line:
                    continue
                self.wfile.write(f"data: {line}\n\n".encode())
                self.wfile.flush()
            proc.wait()
            if proc.returncode != 0:
                err = proc.stderr.read()
                self.wfile.write(
                    f"data: {json.dumps({'error': err})}\n\n".encode()
                )
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except FileNotFoundError:
            self.wfile.write(
                f"data: {json.dumps({'error': 'claude binary not found on PATH'})}\n\n".encode()
            )
        except Exception as exc:
            self.wfile.write(
                f"data: {json.dumps({'error': str(exc)})}\n\n".encode()
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
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
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
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
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
    if HOST != "127.0.0.1" and not SHIM_TOKEN:
        print(
            "[shim] WARNING: bound to a non-local address with NO SHIM_TOKEN — "
            "anyone who reaches this port can spend your Claude subscription. "
            "Set SHIM_TOKEN to require a bearer token.",
            file=sys.stderr,
        )
    # Threaded so a couple of testers don't fully serialize behind one
    # in-flight `claude` call.
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
