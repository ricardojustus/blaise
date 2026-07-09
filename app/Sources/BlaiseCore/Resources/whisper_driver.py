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

# #100 Part A — dominant-language detection constants. Mirror mlx_whisper.audio
# (HOP_LENGTH/N_FRAMES/N_SAMPLES) so window math is identical to the encoder's,
# but kept as pure literals here so the detection seam imports under a bare
# /usr/bin/python3 (no numpy/mlx). The remaining values are PROVISIONAL
# heuristics (pinned by logic tests, calibratable): RMS is the silence/selection
# signal ONLY; the {pt,en} mass + per-window margin are language-window
# confidence heuristics, NOT a speech detector.
HOP_LENGTH = 160          # samples per mel frame (mirror mlx_whisper.audio)
N_FRAMES = 3000           # 30s in mel frames
N_SAMPLES = 480000        # 30s in samples
DETECT_WINDOWS_K = 8      # max windows actually sent to detect_language
DEAD_SILENCE_RMS = 1e-3   # below this normalized RMS = digital silence (selection-excluded)
MIN_PAIR_MASS = 0.5       # require p_pt+p_en >= this share of the language softmax (provisional)
MIN_MARGIN = 0.10         # per-window |p_pt-p_en|/mass must clear this to count as evidence (provisional)
MIN_WINDOWS = 2           # minimum counted windows to trust the multi-window verdict
MIN_TOTAL_MARGIN = 0.5    # sum of counted margins must clear this (else ambiguous -> fallback)


def candidate_detection_starts(num_samples, *, n_samples=N_SAMPLES):
    """ALL non-overlapping 30s window START sample indices, ascending/unique.

    num_samples<=0 -> []; 0<num_samples<n_samples -> [0]; else
    [0, n_samples, 2*n_samples, ... < num_samples]. STDLIB-ONLY."""
    if num_samples <= 0:
        return []
    return list(range(0, num_samples, n_samples))


def select_detection_windows(starts, energies, *, k=DETECT_WINDOWS_K, dead_silence_rms=DEAD_SILENCE_RMS):
    """Choose <=k temporally-diverse, non-dead windows. STDLIB-ONLY. `starts`
    ascending; `energies` index-aligned. Buckets survivors into k contiguous
    equal-count temporal buckets (by index in survivors) and keeps the loudest
    per bucket so loud non-speech can't starve the vote (Codex B2)."""
    if len(starts) != len(energies):
        raise ValueError("starts/energies length mismatch")  # FIRST stmt — zip() silently truncates otherwise
    survivors = [(s, e) for s, e in zip(starts, energies) if math.isfinite(e) and e >= dead_silence_rms]  # preserves ascending
    if len(survivors) <= k:
        return [s for s, _ in survivors]                      # already ascending
    n = len(survivors)
    chosen = []
    for i in range(k):
        lo = i * n // k
        hi = (i + 1) * n // k
        bucket = survivors[lo:hi]
        if bucket:
            chosen.append(max(bucket, key=lambda se: (se[1], -se[0]))[0])  # max energy, tie -> smaller start
    return sorted(chosen)


def detect_dominant_language(window_probs, *, allowed=ALLOWED_LANGUAGES,
                             min_pair_mass=MIN_PAIR_MASS, min_margin=MIN_MARGIN,
                             min_windows=MIN_WINDOWS, min_total_margin=MIN_TOTAL_MARGIN):
    """`window_probs`: list[dict] (one detect_language probs dict per SELECTED
    window). STDLIB-ONLY. Returns an allowed code, or None (insufficient/
    ambiguous -> caller falls back to the single-window clamp). Per-window
    normalize within {pt,en} -> margin-weighted majority vote with a margin
    floor (zero/ambiguous windows are NOT evidence) + a min total margin;
    deterministic tie -> allowed[0] ('pt'). (Codex B3.)"""
    assert len(allowed) == 2
    a, b = allowed
    votes = {a: 0.0, b: 0.0}
    counted = 0
    for p in window_probs:
        pa = p.get(a, 0.0)
        pb = p.get(b, 0.0)
        if not (math.isfinite(pa) and math.isfinite(pb)):
            continue                                          # NaN/Inf -> skip (driver NaN hazard)
        mass = pa + pb
        if mass < min_pair_mass:
            continue                                          # diffuse -> non-speech/ambiguous
        margin = abs(pa - pb) / mass                          # in [0,1]
        if margin < min_margin:
            continue                                          # too ambiguous to be evidence (Codex B3)
        votes[a if pa >= pb else b] += margin
        counted += 1
    if counted < min_windows:
        return None
    if (votes[a] + votes[b]) < min_total_margin:
        return None
    return a if votes[a] >= votes[b] else b                    # deterministic tie -> a ('pt')


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
            # Clamped, temporally-diverse multi-window dominant-language ID
            # (#100 Part A). We still mirror stock transcribe() detection
            # (mlx-whisper 0.4.3 transcribe.py: log_mel_spectrogram over the
            # full audio, pad_or_trim to the standard 30 s N_FRAMES window,
            # model.detect_language → probability dict) and still clamp the
            # argmax to ALLOWED_LANGUAGES, but instead of trusting only the
            # first 30 s we score several non-overlapping 30 s windows spread
            # across the real audio (loudest-per-temporal-bucket selection) and
            # take a margin-weighted majority vote within {pt,en}. On
            # insufficient/ambiguous evidence we fall back to today's EXACT
            # single-first-window clamp. detect_language is a pure forward pass
            # (argmax/softmax, no sampling) — determinism pins below are
            # unaffected. The resulting code is passed as language= so
            # transcribe() skips its own detection and reports it back in
            # result["language"] (honest provenance in the emitted payload).
            #
            # numpy is imported HERE (deferred) so the pure detection seam
            # (candidate_detection_starts / select_detection_windows /
            # detect_dominant_language) stays importable + callable under a
            # bare /usr/bin/python3; `mx` is already in scope (above).
            import numpy as np
            from mlx_whisper.audio import log_mel_spectrogram, pad_or_trim

            model = ModelHolder.get_model(MODEL_REPO, mx.float16)  # cached above
            mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)

            num_samples = int(audio.shape[0])                 # audio is 1-D float32 SAMPLES (load_audio)
            starts = candidate_detection_starts(num_samples)

            def _rms(s):
                chunk = audio[s:s + N_SAMPLES]
                if chunk.size == 0:
                    return 0.0                                 # never NaN into the sort/vote
                return float(np.sqrt(np.mean(np.square(chunk.astype(np.float64)))))

            energies = [_rms(s) for s in starts]
            selected = select_detection_windows(starts, energies)  # <=K ascending starts
            window_probs = []                                 # single lockstep loop, ascending
            for s in selected:
                start_frame = s // HOP_LENGTH                  # samples -> mel frames
                mel_seg = pad_or_trim(
                    mel[..., start_frame:start_frame + N_FRAMES, :], N_FRAMES, axis=-2
                ).astype(mx.float16)
                _, probs = model.detect_language(mel_seg)      # per-window; NO batching in v1
                window_probs.append(probs)
            language = detect_dominant_language(window_probs)
            if language is None:                              # insufficient/ambiguous evidence
                # Byte-identical to today's single-first-window clamp; reuses
                # the same `mel` (log_mel_spectrogram computed exactly once).
                mel_first = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
                _, probs0 = model.detect_language(mel_first)
                language = clamp_language(probs0)

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
