#!/usr/bin/env python3
"""
run_zstd_chia_loop.py -- barebones LLM iteration loop for the zstd RTL.

Cascade: cheapest/fastest model first, escalating on failure. Each model
starts from the original file and gets the previous run's simulation log
as feedback.

Needs:  pip install anthropic google-genai
Env:    ANTHROPIC_API_KEY, GEMINI_API_KEY
"""
import os
import re
import sys
import shutil
import subprocess

import gen_stimulus

# (model_id, provider)
MODELS = [
    ("gemini-3.7-flash-lite", "gemini"),
    ("gemini-3.7-flash",      "gemini"),
    ("claude-haiku-4-5-20251001", "anthropic"),
    ("claude-sonnet-5",           "anthropic"),
    ("claude-opus-5",             "anthropic"),
]

MAX_ITERS = 4
MAX_TOKENS = 16000
ROOT = os.path.abspath(os.path.dirname(__file__))
BACKUP = os.path.join(ROOT, ".chia_backup")

# RTL only. The testbench decides pass/fail, so it is not editable; the
# model/*.c files define the golden vectors, so they are not either.
TARGETS = [
    "rtl/tans_decoder.sv",
    "rtl/lz_reconstruct.sv",
    "rtl/axi_dma_if.sv",
    "rtl/tile_scheduler.sv",
    "rtl/zstd_decomp_top.sv",
    "rtl/desparse_unit.sv",
    "rtl/dequant_unit.sv",
    "rtl/dict_mem.sv",
]

SYSTEM = ("You are an expert digital design engineer fixing synthesizable "
          "SystemVerilog-2012 for Icarus Verilog 12.0.")

PROMPT = """Fix one bug in {path}.

Pipeline: AXI DMA -> tANS/FSE decode -> LZ77 reconstruct -> 2:4 desparse
(bypassed here) -> INT8 dequant (identity). All stages use valid/ready
backpressure. The testbench and golden C model are correct and fixed.

Test vector: FSE table 16 entries (tableLog=4), init_state=1,
num_symbols=10, compressed bytes 76 43 85 44 00.
Decoded symbols: 05 AA BB 0A 11 22 ESCAPE(256) 00 06 06
(ESCAPE then offset_hi, offset_lo, length -> offset=6, length=6).
Expected 12 output bytes: 05 AA BB 0A 11 22 05 AA BB 0A 11 22.

{path}:
```systemverilog
{code}
```

{feedback}

Output the complete fixed file, module through endmodule, in ONE
```systemverilog block. Same ports and parameters. No prose.
"""


# ---------------- simulation ----------------
def run_sim():
    """Returns (passed, score, log). score = scoreboard offsets matched."""
    ok, msg = gen_stimulus.generate(verbose=False)
    if not ok:
        return False, -1, f"Stimulus generation failed:\n{msg}"

    c = subprocess.run("iverilog -g2012 -Itb -o sim.out rtl/*.sv "
                       "tb/tb_zstd_decomp_top.sv",
                       shell=True, capture_output=True, text=True, cwd=ROOT)
    if c.returncode != 0:
        return False, 0, f"COMPILATION FAILED:\n{c.stderr[-1500:]}"

    try:
        s = subprocess.run("vvp sim.out", shell=True, capture_output=True,
                           text=True, cwd=ROOT, timeout=120)
    except subprocess.TimeoutExpired:
        return False, 0, "vvp hung past 120s."

    passed = "[TB] PASS" in s.stdout and s.returncode == 0
    score = len(re.findall(r"\[SCOREBOARD MATCH\]", s.stdout))
    return passed, score, s.stdout[-2000:]


# ---------------- model calls ----------------
_clients = {}


def ask(model, provider, prompt):
    """Returns response text, or None on failure."""
    try:
        if provider == "anthropic":
            import anthropic
            if "anthropic" not in _clients:
                _clients["anthropic"] = anthropic.Anthropic(
                    api_key=os.environ["ANTHROPIC_API_KEY"])
            kw = {}
            # Claude 5 has adaptive thinking that cannot be disabled and will
            # eat the whole budget here; 4.x can be told not to think at all.
            if re.search(r"-(opus|sonnet|haiku)-5", model):
                kw = {"thinking": {"type": "adaptive"},
                      "output_config": {"effort": "low"}}
            else:
                kw = {"thinking": {"type": "disabled"}}
            with _clients["anthropic"].messages.stream(
                    model=model, max_tokens=MAX_TOKENS, system=SYSTEM,
                    messages=[{"role": "user", "content": prompt}], **kw) as st:
                msg = st.get_final_message()
            return "".join(b.text for b in msg.content
                           if getattr(b, "type", "") == "text")

        from google import genai
        if "gemini" not in _clients:
            _clients["gemini"] = genai.Client(
                api_key=os.environ["GEMINI_API_KEY"])
        r = _clients["gemini"].models.generate_content(
            model=model, contents=prompt,
            config={"system_instruction": SYSTEM,
                    "max_output_tokens": MAX_TOKENS})
        return r.text

    except Exception as e:
        print(f"   ! {model}: {e}")
        return None


def extract(text):
    """Take the block that is the whole file, not the first snippet."""
    if not text:
        return ""
    blocks = re.findall(r"```(?:systemverilog|verilog)?\s*\n([\s\S]*?)\n```",
                        text, re.IGNORECASE)
    good = [b for b in blocks
            if "endmodule" in b and re.search(r"^\s*module\s", b, re.M)]
    return max(good, key=len).strip() if good else ""


# ---------------- main ----------------
def main():
    os.makedirs(BACKUP, exist_ok=True)
    for t in TARGETS:
        if os.path.exists(os.path.join(ROOT, t)):
            shutil.copy2(os.path.join(ROOT, t),
                         os.path.join(BACKUP, t.replace("/", "__")))

    passed, score, log = run_sim()
    if passed:
        print("Already passing.")
        return
    print(f"Baseline score: {score}")

    for path in TARGETS:
        full = os.path.join(ROOT, path)
        if not os.path.exists(full):
            continue

        original = open(full).read()
        best_code, best_score = original, score
        print(f"\n=== {path} (score {best_score})")

        for model, provider in MODELS:
            print(f"\n>>> {model}")
            open(full, "w").write(best_code)
            code, feedback = best_code, log

            for i in range(1, MAX_ITERS + 1):
                text = ask(model, provider,
                           PROMPT.format(path=path, code=code, feedback=feedback))
                new = extract(text)
                if not new:
                    print(f"   {i}: no complete module in response")
                    continue

                open(full, "w").write(new)
                code = new
                passed, s, log = run_sim()

                if passed:
                    print(f"   {i}: PASS -- {model} fixed {path}")
                    return
                if s > best_score:
                    print(f"   {i}: score {best_score} -> {s}, keeping")
                    best_score, best_code = s, new
                else:
                    print(f"   {i}: score {s} (best {best_score})")
                feedback = log

            open(full, "w").write(best_code)

        open(full, "w").write(best_code)

    print(f"\nNo pass. Best score {best_score}. Originals in {BACKUP}/")
    sys.exit(1)


if __name__ == "__main__":
    main()
