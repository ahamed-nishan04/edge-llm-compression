#!/usr/bin/env python3
"""
debug_one_call.py -- make ONE model call with the exact prompt the loop
sends for a given target file, stream it to disk, and report what came
back. Use this to find out WHY a response is hitting the token ceiling
instead of guessing at it.

Usage:
    python3 debug_one_call.py                       # tans_decoder.sv
    python3 debug_one_call.py rtl/lz_reconstruct.sv
"""
import os
import sys
import collections

import anthropic

import run_zstd_chia_loop as loop

TARGET = sys.argv[1] if len(sys.argv) > 1 else "rtl/tans_decoder.sv"
RAW_OUT = "/tmp/chia_raw_response.txt"


def main():
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set.")
        sys.exit(1)
    client = anthropic.Anthropic(api_key=api_key)

    target_path = os.path.join(loop.PROJECT_ROOT, TARGET)
    with open(target_path) as f:
        code = f.read()
    print(f"Target: {TARGET}  ({len(code.splitlines())} lines in)")
    print("Running baseline simulation for feedback text...")
    _, score, log = loop.run_simulation()
    feedback = loop.summarize(score, log)

    prompt = loop.PROMPT_TMPL.format(module_path=TARGET, arch=loop.ARCH_SUMMARY,
                                     code=code, feedback=feedback)
    print(f"Prompt: {len(prompt)} chars\n")
    print(f"Streaming response to {RAW_OUT} ...\n")

    chunks = []
    model = os.environ.get("CHIA_MODEL", loop.CANDIDATE_MODELS[0])
    print(f"Model: {model}  config: {loop.thinking_config(model)}\n")
    with client.messages.stream(
        model=model,
        max_tokens=loop.MAX_TOKENS,
        system=loop.SYS_ROLE,
        messages=[{"role": "user", "content": prompt}],
        **loop.thinking_config(model),
    ) as stream:
        for text in stream.text_stream:
            chunks.append(text)
            # progress dots so you can see it running away in real time
            if sum(len(c) for c in chunks) % 20000 < len(text):
                print(f"  ... {sum(len(c) for c in chunks)} chars so far")
        final = stream.get_final_message()

    raw = "".join(chunks)
    with open(RAW_OUT, "w") as f:
        f.write(raw)

    lines = raw.splitlines()
    print("\n" + "=" * 55)
    print(f"stop_reason   : {final.stop_reason}")
    print(f"output tokens : {final.usage.output_tokens}")
    think = getattr(getattr(final.usage, "output_tokens_details", None),
                    "thinking_tokens", "?")
    print(f"thinking tok  : {think}")
    print(f"block types   : {[b.type for b in final.content]}")
    print(f"raw chars     : {len(raw)}")
    print(f"raw lines     : {len(lines)}")
    print(f"```  fences   : {raw.count('```')}")
    print(f"'endmodule'   : {raw.count('endmodule')}")
    print(f"'module '     : {raw.count('module ')}")

    # A degenerate repeat shows up as a handful of lines repeated hundreds
    # of times. This makes that obvious immediately.
    counts = collections.Counter(l.strip() for l in lines if l.strip())
    print("\nMost repeated non-blank lines:")
    for line, n in counts.most_common(8):
        print(f"  {n:5d}x  {line[:75]}")

    print("\n--- first 15 lines ---")
    for l in lines[:15]:
        print("  " + l[:100])
    print("\n--- last 15 lines ---")
    for l in lines[-15:]:
        print("  " + l[:100])
    print("=" * 55)
    print(f"\nFull text saved to {RAW_OUT}")


if __name__ == "__main__":
    main()
