# Blaise notes-synthesis driver (C6 spec; G14 adds the --digest mode).
#
# Argv contract: <venv-python> notes_driver.py --blaise-engine [--kv-probe N]
#                                               [--digest]
# (--blaise-engine is an inert marker so the orphan sweep can identify stray
# driver processes unambiguously.)
#
# Default mode reads ONE JSON request from stdin:
#   {system, user, schema, max_input_tokens, max_output_tokens,
#    temperature, top_p}
# and writes ONE JSON document to stdout:
#   {notes: <schema-conforming object>, usage: {input_tokens, output_tokens},
#    stats: {prompt_tps, generation_tps, peak_memory_gb}}
# JSON shape is enforced by Outlines constrained decoding (from_mlxlm).
#
# --digest mode (G14) reads ONE JSON request from stdin:
#   {system, user, max_input_tokens, max_output_tokens, temperature, top_p}
# (NO schema — the memory digest is free-form Markdown, not a schema-shaped
# document, so generation is UNCONSTRAINED) and writes ONE JSON document:
#   {digest: <markdown string>, usage: {input_tokens, output_tokens},
#    stats: {prompt_tps, generation_tps, peak_memory_gb}}
#
# --kv-probe N: synthetic ~N-token prompt prefilled + 100 tokens generated,
# peak memory reported (the C6 smoke gate calibrates maxInputTokens with it).
#
# Exit codes: 0 ok; 2 bad input; 3 model load failure; 4 generation failure.
# Detail goes to stderr. Input over budget exits 2 with the sentinel prefix
# "BLAISE_INPUT_TOO_LONG:" (the Swift side maps it to the inputTooLong
# fallback reason; the exact tokenizer count computed here, before any
# generation, is the only refusal authority).

import json
import sys
import traceback

EXIT_BAD_INPUT = 2
EXIT_MODEL_LOAD = 3
EXIT_GENERATE = 4

MODEL_REPO = "mlx-community/gemma-4-26b-a4b-it-4bit"

# Gemma 4 thinking mode is disabled explicitly (deterministic notes; no
# hidden tokens billed against time). Verified against the downloaded chat
# template (chat_template.jinja, 2026-06-10): the template reads an
# `enable_thinking` kwarg; when falsy it emits a closed empty
# `<|channel>thought` block in the generation prompt, which suppresses
# thinking.
CHAT_TEMPLATE_KWARGS = {"enable_thinking": False}


def fail(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def parse_args(argv):
    saw_marker = False
    kv_probe = None
    digest = False
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--blaise-engine":
            saw_marker = True
        elif arg == "--digest":
            digest = True
        elif arg == "--kv-probe":
            i += 1
            if i >= len(argv):
                fail(EXIT_BAD_INPUT, "bad input: --kv-probe requires a value")
            try:
                kv_probe = int(argv[i])
            except ValueError:
                fail(EXIT_BAD_INPUT, f"bad input: --kv-probe value {argv[i]!r} is not an int")
        else:
            fail(EXIT_BAD_INPUT, f"bad input: unknown argument {arg!r}")
        i += 1
    if not saw_marker:
        fail(EXIT_BAD_INPUT, "bad input: missing --blaise-engine marker")
    return kv_probe, digest


def load_model():
    # Distinct model-load stage so cache corruption surfaces as exit 3
    # (suspect flag + wipe-repair on the Swift side).
    try:
        import mlx_lm

        return mlx_lm.load(MODEL_REPO)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(EXIT_MODEL_LOAD)


def encode_prompt(tokenizer, prompt):
    # Mirror outlines' mlxlm handling: avoid double BOS when the chat
    # template already starts with it.
    bos = tokenizer.bos_token
    add_special = bos is None or not prompt.startswith(bos)
    return tokenizer.encode(prompt, add_special_tokens=add_special)


def kv_probe(token_target):
    model, tokenizer = load_model()
    sentence = (
        "Esta é uma frase sintética de calibração de memória para a sonda de "
        "contexto longo do Blaise, com palavras comuns em português. "
    )
    ids = encode_prompt(tokenizer, sentence)
    while len(ids) < token_target:
        ids = ids + ids
    ids = ids[:token_target]

    try:
        from mlx_lm.generate import stream_generate

        last = None
        for response in stream_generate(model, tokenizer, ids, max_tokens=100):
            last = response
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(EXIT_GENERATE)

    json.dump(
        {
            "prompt_tokens": last.prompt_tokens,
            "generation_tokens": last.generation_tokens,
            "prompt_tps": last.prompt_tps,
            "generation_tps": last.generation_tps,
            "peak_memory_gb": last.peak_memory,
        },
        sys.stdout,
    )
    sys.stdout.write("\n")
    sys.stdout.flush()


def generate_digest():
    # G14: free-text Markdown generation (NO Outlines schema constraint — the
    # memory digest is Markdown, not a schema-shaped document).
    try:
        request = json.load(sys.stdin)
        system = request["system"]
        user = request["user"]
        max_input_tokens = int(request["max_input_tokens"])
        max_output_tokens = int(request["max_output_tokens"])
        temperature = float(request["temperature"])
        top_p = float(request["top_p"])
    except Exception as e:
        fail(EXIT_BAD_INPUT, f"bad input: malformed stdin request: {e}")

    model, tokenizer = load_model()

    try:
        prompt = tokenizer.apply_chat_template(
            [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            tokenize=False,
            add_generation_prompt=True,
            **CHAT_TEMPLATE_KWARGS,
        )
    except Exception as e:
        fail(EXIT_BAD_INPUT, f"bad input: chat template rejected the request: {e}")

    ids = encode_prompt(tokenizer, prompt)
    if len(ids) > max_input_tokens:
        fail(
            EXIT_BAD_INPUT,
            f"BLAISE_INPUT_TOO_LONG: {len(ids)} tokens > {max_input_tokens} budget",
        )

    try:
        from mlx_lm.generate import stream_generate
        from mlx_lm.sample_utils import make_sampler

        sampler = make_sampler(temp=temperature, top_p=top_p)
        parts = []
        last = None
        for response in stream_generate(
            model,
            tokenizer,
            ids,
            max_tokens=max_output_tokens,
            sampler=sampler,
        ):
            parts.append(response.text)
            last = response
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(EXIT_GENERATE)

    digest = "".join(parts)

    json.dump(
        {
            "digest": digest,
            "usage": {
                "input_tokens": last.prompt_tokens,
                "output_tokens": last.generation_tokens,
            },
            "stats": {
                "prompt_tps": last.prompt_tps,
                "generation_tps": last.generation_tps,
                "peak_memory_gb": last.peak_memory,
            },
        },
        sys.stdout,
        ensure_ascii=False,
        allow_nan=False,
    )
    sys.stdout.write("\n")
    sys.stdout.flush()


def main():
    probe, digest = parse_args(sys.argv)
    if probe is not None:
        kv_probe(probe)
        return
    if digest:
        generate_digest()
        return

    try:
        request = json.load(sys.stdin)
        system = request["system"]
        user = request["user"]
        schema = request["schema"]
        max_input_tokens = int(request["max_input_tokens"])
        max_output_tokens = int(request["max_output_tokens"])
        temperature = float(request["temperature"])
        top_p = float(request["top_p"])
    except Exception as e:
        fail(EXIT_BAD_INPUT, f"bad input: malformed stdin request: {e}")

    model, tokenizer = load_model()

    try:
        prompt = tokenizer.apply_chat_template(
            [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            tokenize=False,
            add_generation_prompt=True,
            **CHAT_TEMPLATE_KWARGS,
        )
    except Exception as e:
        fail(EXIT_BAD_INPUT, f"bad input: chat template rejected the request: {e}")

    ids = encode_prompt(tokenizer, prompt)
    if len(ids) > max_input_tokens:
        fail(
            EXIT_BAD_INPUT,
            f"BLAISE_INPUT_TOO_LONG: {len(ids)} tokens > {max_input_tokens} budget",
        )

    try:
        import outlines
        from outlines.types import JsonSchema

        outlines_model = outlines.from_mlxlm(model, tokenizer)
        generator = outlines.Generator(outlines_model, JsonSchema(json.dumps(schema)))
        processor = generator.logits_processor
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(EXIT_GENERATE)

    try:
        from mlx_lm.generate import stream_generate
        from mlx_lm.sample_utils import make_sampler

        sampler = make_sampler(temp=temperature, top_p=top_p)
        parts = []
        last = None
        for response in stream_generate(
            model,
            tokenizer,
            ids,
            max_tokens=max_output_tokens,
            sampler=sampler,
            logits_processors=[processor],
        ):
            parts.append(response.text)
            last = response
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(EXIT_GENERATE)

    text = "".join(parts)
    if last is not None and last.finish_reason == "length":
        fail(EXIT_GENERATE, f"generation hit max_tokens ({max_output_tokens}) before completing JSON")

    try:
        notes = json.loads(text)
    except Exception as e:
        fail(EXIT_GENERATE, f"constrained output was not parseable JSON: {e}")

    json.dump(
        {
            "notes": notes,
            "usage": {
                "input_tokens": last.prompt_tokens,
                "output_tokens": last.generation_tokens,
            },
            "stats": {
                "prompt_tps": last.prompt_tps,
                "generation_tps": last.generation_tps,
                "peak_memory_gb": last.peak_memory,
            },
        },
        sys.stdout,
        ensure_ascii=False,
        allow_nan=False,
    )
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
