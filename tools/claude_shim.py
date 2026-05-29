#!/usr/bin/env python3
"""Local HTTP shim that wraps `claude --print` for the Careblazers
dev-mode LLM provider.

Listens on http://localhost:8765/generate. Accepts POST JSON of shape:
  {"system": "...", "user": "..."}
Returns Server-Sent Events (SSE) streaming the model's response.

Usage:
  python3 tools/claude_shim.py
"""

import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8765
CLAUDE_CMD = "claude"


class Handler(BaseHTTPRequestHandler):
    def _bad(self, code, msg):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode())

    def do_POST(self):
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
            CLAUDE_CMD, "--print", "--output-format", "stream-json",
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
    print(f"[shim] Careblazers LLM shim listening on http://localhost:{PORT}")
    print(f"[shim] Uses local `{CLAUDE_CMD}` binary (your Claude Max subscription).")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
