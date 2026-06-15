# Blaise mlx-whisper driver (C3 spec).
#
# Argv contract: <venv-python> whisper_driver.py --blaise-engine --audio <wav> [--language <code>]
# (--blaise-engine is an inert marker so the orphan sweep can identify stray
# driver processes unambiguously.)
#
# Exit codes: 0 ok; 2 bad input; 3 model load failure; 4 transcribe failure.
# Detail goes to stderr. Exactly ONE JSON document on stdout:
#   {text, language, segments: [{start, end, text, no_speech_prob,
#    avg_logprob, words: [{word, start, end} ...]} ...]}
#
# Audio decode uses stdlib `wave` + numpy: the stock mlx_whisper CLI shells
# out to ffmpeg for ALL decode (mlx_whisper/audio.py), which we must not
# depend on; Blaise always feeds 16 kHz mono PCM WAV it produced itself.

import json
import math
import sys
import traceback

EXIT_BAD_INPUT = 2
EXIT_MODEL_LOAD = 3
EXIT_TRANSCRIBE = 4

MODEL_REPO = "mlx-community/whisper-large-v3-turbo"

# Language clamp (field failure, an early recording): Whisper's
# unrestricted language ID rendered real PT/EN speech as Italian on one track
# and as Cyrillic hallucination on the other (acoustic bleed in two-track,
# no-headphones capture defeats it). Blaise meetings are by product definition
# always Portuguese, English, or PT/EN code-switched (Brazilian PT/EN product scope), so
# auto-detection selects the argmax WITHIN this set only.
ALLOWED_LANGUAGES = ("pt", "en")


def clamp_language(probs):
    """Argmax over the model's language probability distribution restricted
    to ALLOWED_LANGUAGES. `probs` is the {code: probability} dict returned by
    mlx_whisper's model.detect_language for a single mel segment."""
    return max(ALLOWED_LANGUAGES, key=lambda code: probs.get(code, 0.0))


def fail(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def parse_args(argv):
    audio = None
    language = None
    saw_marker = False
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--blaise-engine":
            saw_marker = True
        elif arg == "--audio":
            i += 1
            if i >= len(argv):
                fail(EXIT_BAD_INPUT, "bad input: --audio requires a value")
            audio = argv[i]
        elif arg == "--language":
            i += 1
            if i >= len(argv):
                fail(EXIT_BAD_INPUT, "bad input: --language requires a value")
            language = argv[i]
        else:
            fail(EXIT_BAD_INPUT, f"bad input: unknown argument {arg!r}")
        i += 1
    if not saw_marker:
        fail(EXIT_BAD_INPUT, "bad input: missing --blaise-engine marker")
    if audio is None:
        fail(EXIT_BAD_INPUT, "bad input: missing --audio")
    return audio, language


def load_audio(path):
    import wave

    import numpy as np

    try:
        with wave.open(path, "rb") as w:
            if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
                fail(
                    EXIT_BAD_INPUT,
                    "bad input: expected 16 kHz mono 16-bit PCM WAV, got "
                    f"{w.getframerate()} Hz / {w.getnchannels()} ch / {8 * w.getsampwidth()} bit",
                )
            frames = w.readframes(w.getnframes())
    except (wave.Error, FileNotFoundError, IsADirectoryError, PermissionError, EOFError, OSError) as e:
        fail(EXIT_BAD_INPUT, f"bad input: cannot read WAV {path!r}: {e}")
    return np.frombuffer(frames, np.int16).astype(np.float32) / 32768.0


def validate_language(language):
    if language is None:
        return None
    from mlx_whisper.tokenizer import LANGUAGES, TO_LANGUAGE_CODE

    code = language.lower()
    if code in LANGUAGES:
        return code
    if code in TO_LANGUAGE_CODE:
        return TO_LANGUAGE_CODE[code]
    fail(EXIT_BAD_INPUT, f"bad input: unknown language {language!r}")


def main():
    audio_path, language = parse_args(sys.argv)
    audio = load_audio(audio_path)
    language = validate_language(language)

    # Distinct model-load stage so cache corruption surfaces as exit 3
    # (suspect flag + wipe-repair on the Swift side), not a generic failure.
    # ModelHolder caches per (repo, dtype); transcribe() below reuses it.
    try:
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder

        ModelHolder.get_model(MODEL_REPO, mx.float16)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(EXIT_MODEL_LOAD)

    try:
        import mlx_whisper

        if language is None:
            # Clamped language ID, mirroring stock transcribe() detection
            # (mlx-whisper 0.4.3 transcribe.py: log_mel_spectrogram over the
            # full audio, pad_or_trim to the standard 30 s N_FRAMES window,
            # model.detect_language → probability dict) except the argmax is
            # taken within ALLOWED_LANGUAGES instead of all 100 languages.
            # detect_language is a pure forward pass (argmax/softmax, no
            # sampling) — determinism pins below are unaffected. The clamped
            # code is passed as language= so transcribe() skips its own
            # detection and reports it back in result["language"] (honest
            # provenance in the emitted payload).
            from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim

            model = ModelHolder.get_model(MODEL_REPO, mx.float16)  # cached above
            mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
            mel_segment = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
            _, probs = model.detect_language(mel_segment)
            language = clamp_language(probs)

        # Determinism + anti-hallucination (verified against the installed
        # mlx-whisper 0.4.3 source, transcribe.py/decoding.py):
        # - mx.random.seed: the temperature-fallback decode path samples via
        #   the GLOBAL mlx PRNG (decoding.py: mx.random.categorical); unseeded,
        #   two runs over the same audio diverge wherever a fallback fires
        #   (measured 0.917 word-similarity across two full-sample runs).
        # - condition_on_previous_text=False: with conditioning on, one
        #   window's repetition loop ("é é é …", "tchau tchau …") propagates
        #   into following windows, replacing real speech — the C7 two-run
        #   mint surfaced loops destroying different ~40-word spans per run.
        #   Independent windows keep any failure local (standard Whisper
        #   hallucination mitigation; quality > inter-window style cohesion).
        mx.random.seed(0)
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=MODEL_REPO,
            word_timestamps=True,
            language=language,
            condition_on_previous_text=False,
            verbose=None,
        )
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(EXIT_TRANSCRIBE)

    def finite(value):
        # mlx-whisper occasionally emits NaN/Infinity for probabilities;
        # Python json.dumps writes them (non-standard JSON) and Foundation's
        # decoder rejects the whole document. Strict JSON: non-finite -> None.
        if isinstance(value, float) and not math.isfinite(value):
            return None
        return value

    segments = []
    for seg in result.get("segments", []):
        segments.append(
            {
                "start": finite(seg["start"]),
                "end": finite(seg["end"]),
                "text": seg["text"],
                "no_speech_prob": finite(seg.get("no_speech_prob")),
                "avg_logprob": finite(seg.get("avg_logprob")),
                "words": [
                    {"word": w["word"], "start": finite(w["start"]), "end": finite(w["end"])}
                    for w in seg.get("words", [])
                ],
            }
        )
    output = {
        "text": result.get("text", ""),
        "language": result.get("language"),
        "segments": segments,
    }
    json.dump(output, sys.stdout, ensure_ascii=False, allow_nan=False)
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
