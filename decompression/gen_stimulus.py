#!/usr/bin/env python3
"""
gen_stimulus.py -- build tb/generated_stimulus.svh from the golden C model.

  1. gcc model/fse_codec.c -DFSE_CODEC_SELFTEST   -> round-trip sanity gate
  2. gcc model/compute_test_vectors.c             (it #includes fse_codec.c)
  3. run it, parse stdout
  4. emit tb/generated_stimulus.svh

Emits exactly the GEN_* identifiers tb_zstd_decomp_top.sv references:
  GEN_TILE_SIZE_BYTES, GEN_INIT_STATE, GEN_NUM_SYMBOLS,
  GEN_NUM_COMP_BYTES, GEN_COMP_BYTES[],
  GEN_NUM_TABLE_ENTRIES, GEN_TABLE_ADDR[], GEN_TABLE_SYMBOL[],
  GEN_TABLE_NBBITS[], GEN_TABLE_NEWSTATE[],
  GEN_EXPECTED_LZ_BYTES[]

Run this BEFORE iverilog -- the tb `include`s the .svh, so without it
compilation fails outright.
"""
import os
import re
import subprocess
import sys

PROJECT_ROOT = os.path.abspath(os.path.dirname(__file__))
VECTORS_SRC = os.path.join(PROJECT_ROOT, "model", "compute_test_vectors.c")
CODEC_SRC = os.path.join(PROJECT_ROOT, "model", "fse_codec.c")
STIM_OUT = os.path.join(PROJECT_ROOT, "tb", "generated_stimulus.svh")
BUILD_DIR = os.path.join(PROJECT_ROOT, ".build")


def _compile_and_run(src, out_name, defines=None):
    os.makedirs(BUILD_DIR, exist_ok=True)
    exe = os.path.join(BUILD_DIR, out_name)

    cmd = ["gcc", "-std=c11", "-O1"]
    for d in (defines or []):
        cmd.append(f"-D{d}")
    cmd += [src, "-o", exe, "-lm"]

    res = subprocess.run(cmd, capture_output=True, text=True, cwd=PROJECT_ROOT)
    if res.returncode != 0:
        return False, "", f"Compile failed:\n{res.stderr}"

    run = subprocess.run([exe], capture_output=True, text=True, cwd=PROJECT_ROOT)
    if run.returncode != 0:
        return False, run.stdout, f"Run failed (rc={run.returncode}):\n{run.stderr}"
    return True, run.stdout, ""


def run_codec_selftest():
    ok, out, err = _compile_and_run(CODEC_SRC, "fse_selftest",
                                    defines=["FSE_CODEC_SELFTEST"])
    if not ok:
        return False, err
    if "ROUND TRIP PASS" not in out:
        return False, f"Round trip did not pass:\n{out[-1500:]}"
    return True, "FSE codec round trip OK"


# ---- parsers, keyed to the exact printf formats in compute_test_vectors.c ----

RE_TABLE = re.compile(
    r"table_wr_addr=\s*(\d+)\s+table_wr_symbol=\s*(\d+)\s+"
    r"table_wr_nbbits=\s*(\d+)\s+table_wr_newstate_base=\s*(\d+)"
)
RE_BYTE = re.compile(r"byte\[(\d+)\]\s*=\s*0x([0-9a-fA-F]{2})")
RE_INIT_STATE = re.compile(r"^init_state\s*=\s*(\d+)", re.M)
RE_NUM_SYMBOLS = re.compile(r"^num_symbols\s*=\s*(\d+)", re.M)
# NOTE: the scoreboard checks LZ-reconstructed bytes (desparse bypassed,
# dequant is identity), so lz_out[] is the expected stream -- NOT ds_out[]
# and NOT the final dequantized out[].
RE_LZ = re.compile(r"lz_out\[(\d+)\]\s*=\s*0x([0-9a-fA-F]{2})")


def _ordered(pairs, what):
    d = {int(i): v for i, v in pairs}
    if not d:
        return []
    n = max(d) + 1
    missing = [i for i in range(n) if i not in d]
    if missing:
        raise ValueError(f"gap in {what} indices: missing {missing[:8]}")
    return [d[i] for i in range(n)]


def parse_vectors(stdout):
    table = [(int(a), int(s), int(nb), int(ns))
             for a, s, nb, ns in RE_TABLE.findall(stdout)]
    table.sort(key=lambda r: r[0])
    if not table:
        raise ValueError("no table_wr_* lines found")

    comp = _ordered([(i, int(v, 16)) for i, v in RE_BYTE.findall(stdout)], "comp byte")
    if not comp:
        raise ValueError("no compressed byte[] lines found")

    m = RE_INIT_STATE.search(stdout)
    if not m:
        raise ValueError("no init_state line found")
    init_state = int(m.group(1))

    m = RE_NUM_SYMBOLS.search(stdout)
    if not m:
        raise ValueError("no num_symbols line found")
    num_symbols = int(m.group(1))

    lz = _ordered([(i, int(v, 16)) for i, v in RE_LZ.findall(stdout)], "lz_out")
    if not lz:
        raise ValueError("no lz_out[] lines found")

    return {"table": table, "comp": comp, "init_state": init_state,
            "num_symbols": num_symbols, "lz": lz}


def _fill_array(name, vals, width, hexfmt=True):
    """iverilog 12.0 supports neither unpacked-array localparams nor
    declaration initializers on arrays, so emit a plain array declaration
    plus an element-wise `initial` fill."""
    lines = [f"logic [{width-1}:0] {name} [0:{len(vals)-1}];", "initial begin"]
    per_line = 6
    for i in range(0, len(vals), per_line):
        chunk = vals[i:i + per_line]
        parts = []
        for j, b in enumerate(chunk):
            lit = f"{width}'h{b:02x}" if hexfmt else f"{width}'d{b}"
            parts.append(f"{name}[{i+j}] = {lit};")
        lines.append("    " + " ".join(parts))
    lines.append("end")
    return lines


def write_stimulus_include(v, path=STIM_OUT):
    t = v["table"]
    L = []
    L.append("// ============================================================")
    L.append("// generated_stimulus.svh -- AUTO-GENERATED, DO NOT EDIT")
    L.append("// Source: model/compute_test_vectors.c (via gen_stimulus.py)")
    L.append("// Regenerate: python3 gen_stimulus.py")
    L.append("//")
    L.append("// The array fills below are `initial` blocks. iverilog runs")
    L.append("// initial blocks in source order, and this file is included at")
    L.append("// the TOP of the tb module, so these run before the tb's own")
    L.append("// time-0 AXI `mem` init that reads GEN_COMP_BYTES. Keep the")
    L.append("// `include` first in the module -- moving it below the mem")
    L.append("// initial block would read X's.")
    L.append("// ============================================================")
    L.append("")
    L.append(f"localparam int GEN_TILE_SIZE_BYTES   = {len(v['lz'])};")
    L.append(f"localparam int GEN_NUM_COMP_BYTES    = {len(v['comp'])};")
    L.append(f"localparam int GEN_NUM_TABLE_ENTRIES = {len(t)};")
    # Vectors, not `int`: the tb part-selects GEN_INIT_STATE[11:0] and
    # GEN_NUM_SYMBOLS[15:0].
    L.append(f"localparam logic [31:0] GEN_INIT_STATE  = 32'd{v['init_state']};")
    L.append(f"localparam logic [31:0] GEN_NUM_SYMBOLS = 32'd{v['num_symbols']};")
    L.append("")
    L.append("// ---- FSE decode table preload ----")
    L += _fill_array("GEN_TABLE_ADDR", [r[0] for r in t], 12, hexfmt=False)
    L += _fill_array("GEN_TABLE_SYMBOL", [r[1] for r in t], 9, hexfmt=False)
    L += _fill_array("GEN_TABLE_NBBITS", [r[2] for r in t], 5, hexfmt=False)
    L += _fill_array("GEN_TABLE_NEWSTATE", [r[3] for r in t], 12, hexfmt=False)
    L.append("")
    L.append("// ---- compressed bitstream (loaded into AXI memory model) ----")
    L += _fill_array("GEN_COMP_BYTES", v["comp"], 8)
    L.append("")
    L.append("// ---- expected LZ-reconstructed bytes (scoreboard target) ----")
    L += _fill_array("GEN_EXPECTED_LZ_BYTES", v["lz"], 8)
    L.append("")

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(L))
    return path


def generate(verbose=True):
    ok, msg = run_codec_selftest()
    if not ok:
        return False, f"fse_codec self-test failed:\n{msg}"
    if verbose:
        print(f"-> {msg}")

    ok, stdout, err = _compile_and_run(VECTORS_SRC, "gen_vectors")
    if not ok:
        return False, f"compute_test_vectors failed:\n{err}"

    try:
        v = parse_vectors(stdout)
    except ValueError as e:
        return False, f"Could not parse generator output: {e}\n\n{stdout[-1500:]}"

    path = write_stimulus_include(v)
    return True, (f"Wrote {path}: table={len(v['table'])} entries, "
                  f"comp={len(v['comp'])} bytes, init_state={v['init_state']}, "
                  f"num_symbols={v['num_symbols']}, tile={len(v['lz'])} bytes")


if __name__ == "__main__":
    ok, msg = generate()
    print(msg)
    sys.exit(0 if ok else 1)
