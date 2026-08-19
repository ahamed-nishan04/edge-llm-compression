# References

Annotated bibliography for the edge-LLM compression/decompression accelerator project. Grouped by pipeline stage. Drop the actual PDFs into this folder (e.g. `pruning/`, `quantization/`, `entropy-hw/`, `kv-cache/` subfolders) as you collect them — filenames below are suggested names, not required.

## 1. Pruning

- **Frantar & Alistarh, "SparseGPT: Massive Language Models Can Be Accurately Pruned in One-Shot"** (ICML 2023) — arXiv:2301.00774
  One-shot layer-wise pruning using approximate second-order (Hessian) weight reconstruction; reaches 50–60% unstructured sparsity on 100B+ parameter models in hours without retraining, and generalizes to semi-structured 2:4/4:8 patterns compatible with weight quantization. This is the pruning stage used before AWQ in this pipeline.

- **Su & Wang, "ROSE: Reordered SparseGPT for More Accurate One-Shot LLM Pruning"** — arXiv:2603.05878
  Studies the effect of pruning *order* within the SparseGPT framework and proposes prioritizing columns/blocks with larger potential reconstruction error; useful background if pruning-order sensitivity shows up during ablation.

## 2. Quantization

- **Shen et al., "LLM-QAT: Data-Free Quantization Aware Training for Large Language Models"** (2023)
  First QAT method for LLMs; generates synthetic calibration data and distills the full-precision model's output/activation/weight distributions into the quantized model without needing the original training corpus — directly relevant to the QAT/QAFT recovery stage after pruning + AWQ.

- **Chen et al., "EfficientQAT: Efficient Quantization-Aware Training for Large Language Models"** — arXiv:2407.11062
  Splits QAT into block-wise full-parameter training followed by end-to-end training of only the quantization step sizes, making QAT tractable on a single high-end GPU even for 70B models — a practical reference for keeping the QAFT stage affordable on the project's compute budget.

- **Mao, Chen & Kang, "SASQ: Static Activation Scaling for Quantization-Aware Training in LLMs"** — arXiv:2512.14481
  Lightweight QAT variant that only trains activation quantization *factors* (weights untouched), aimed at avoiding the cost of full QAT while keeping static (edge-friendly) inference — useful alternative if full QAFT proves too expensive.

## 3. Entropy Coding / Compression Hardware

- **Yubeaton et al., "Huff-LLM: End-to-End Lossless Compression for Efficient LLM Inference"** — arXiv:2502.00922
  Hardware-friendly Huffman decompression integrated directly into systolic-array / vector LLM accelerators, addressing the core hardware problem of variable-length codes (bubble cycles when no codeword match is found) inside a fixed-throughput MAC pipeline. Directly analogous to the tANS/FSE decode-core problem this project's decompression accelerator has to solve, and a good comparison point for the Huffman-vs-ANS tradeoff.

- **(cited within Huff-LLM) Hao et al., 2024** — ANS-based exponent-bit compression for BF16 weights loaded compressed onto GPU/TPU, ~33% compression with inference-time decode overhead. Relevant prior art for tANS-based tile decompression specifically (vs. Huffman).

- **Ecco (cited in "Large Language Model Inference Acceleration: A Comprehensive Hardware Perspective", arXiv:2410.04466)** — combines group-wise/non-uniform quantization with shared k-means codebooks and Huffman coding for LLM *cache* data, with a parallel multi-stage Huffman decode pipeline reaching GPU-L2-cache-comparable throughput. Closest existing design to the "compress the dynamic KV cache in hardware, in real time" goal of this project's compression accelerator.

- **"Large Language Model Inference Acceleration: A Comprehensive Hardware Perspective"** (survey) — arXiv:2410.04466
  Broad survey of quantization + compression schemes mapped onto GPU/FPGA/ASIC/PIM accelerators; useful as a related-work map for positioning this project's tile-wise Zstd accelerator against existing Huffman/ANS/tensor-train approaches.

## 4. KV-Cache Compression

- **Liu et al., "KIVI: A Tuning-Free Asymmetric 2-bit Quantization for KV Cache"** (cited across surveys below)
  Per-channel quantization for Key cache, per-token quantization for Value cache, motivated by differing outlier statistics between K and V; a software-side reference point for how this project's KV-cache Zstd library should treat K vs. V tiles differently.

- **"KV Cache Compression for Inference Efficiency in LLMs: A Review"** — arXiv:2508.06297
  Survey covering token-eviction (H2O, SnapKV, Keyformer), quantization (KIVI), and attention-compression approaches to KV-cache reduction; useful for justifying why quantization + entropy coding (this project's approach) is complementary to, not competing with, eviction-based methods.

- **"KV Cache Optimization Strategies for Scalable and Efficient LLM Inference"** — arXiv:2603.20397
  More recent survey categorizing KV-cache work into eviction, compression/reconstruction, hybrid memory, and novel attention mechanisms; includes hardware/software co-design as an explicit open direction, which is exactly the gap this project's real-time compression accelerator targets.

## 5. Edge NPU / FPGA LLM Accelerators (context for Shrutam-2 / Sooktam integration)

- **Qiao, Cheng, Zhang, Wang & Huang, "TeLLMe: An Energy-Efficient Ternary LLM Accelerator for Prefilling and Decoding on Edge FPGAs"** — arXiv:2504.16266
  End-to-end edge-FPGA accelerator for ternary-quantized LLMs handling both prefill and decode, with explicit discussion of on-chip BRAM/URAM constraints and growing-KV-cache pressure on edge hardware — same resource-constrained framing as this project's target NPUs.

- **"PD-Swap: Prefill-Decode Logic Swapping for End-to-End LLM Inference on Edge FPGAs via Dynamic Partial Reconfiguration"** — arXiv:2512.11550
  Documents the prefill/decode asymmetry (compute-bound vs. DRAM-bandwidth-bound) that motivates treating static-weight decompression and dynamic-KV compression as two separately optimized datapaths rather than one, which is the design split this project follows.

## 6. Overall Reference for intial idea

- **Han, Mao & Dally, "Deep Compression: Compressing Deep Neural Networks with Pruning, Trained Quantization and Huffman Coding" (ICLR 2016)** - arXiv:1510.00149
Introduces a foundational three-stage compression pipeline consisting of pruning, trained quantization, and Huffman coding. This seminal paper significantly reduces the storage requirements of neural networks without loss of accuracy, making it a highly relevant predecessor to the three-stage compression/decompression pipeline targeted in this project's edge accelerator design.

## Suggested folder layout once PDFs are added

```
references/
├── README.md
├── pruning/
│   └── sparsegpt_2301.00774.pdf
├── quantization/
│   ├── awq_2306.00978.pdf
│   └── llm_qat.pdf
├── entropy-hw/
│   └── huff_llm_2502.00922.pdf
└── kv-cache/
    └── kv_cache_review_2508.06297.pdf
```
