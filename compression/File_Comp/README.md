# Zstandard (Zstd) Hardware Accelerator

## Project Status
* **Compression Pipeline:** V1 Implemented (Testing & Debugging Phase)
* **Decompression Pipeline:** Work in Progress (WIP)

## Overview
This project implements a high-performance, hardware-accelerated pipeline for the Zstandard (Zstd) compression algorithm. The hardware architecture is specifically tuned to mirror the exhaustive optimal-parse strategy of Zstd's Level-22 (`btultra2`) parameter set. 

The current repository contains the complete RTL for the compression half of the accelerator, featuring a deep processing pipeline running from AXI-streamed data ingestion down to standard-compliant Huffman and FSE bitstream generation.

## Architecture: Compression Pipeline

The compression engine operates through a heavily pipelined, multi-stage architecture:

1. **Input Subsystem (`input_subsystem.v`)**: Fetches raw data from memory via an AXI read channel.
2. **Hash & Bloom (`rolling_hash_gen.v`, `bloom_filter.v`)**: Computes rolling hashes and filters unlikely match candidates to reduce Content-Addressable Memory (CAM) access power/contention.
3. **Match Finder (`cam_array.v`, `tree_walkers.v`)**: Uses a multi-banked CAM array and parallel tree walkers to identify and extend LZ77 match sequences within the historical sliding window.
4. **Candidate Filtering (`topk_heap.v`)**: Selects the top-K optimal match lengths and offsets to forward to the Dynamic Programming (DP) engine.
5. **Cost Evaluation (`price_calculator.v`)**: Computes the bit-cost of literal and match emissions based on dynamically generated FSE and Huffman tables.
6. **Dynamic Programming Engine (`dp_engine.v`)**: Implements an exhaustive optimal-parse DP algorithm. Pruning is disabled (`PRUNE_MARGIN = 0x7FFF`) to evaluate every reachable state, matching the `btultra2` compression strategy.
7. **Backtracker (`backtracker.v`)**: Traverses the optimal path computed by the DP engine to emit the final sequence of literals and matches.
8. **Entropy Encoding (`stats_collector.v`, `entropy_encoder.v`)**: Two-pass entropy coding. Pass 1 builds frequency tables and normalized FSE/Huffman weights. Pass 2 packs the symbols into the final compressed bitstream.
9. **Output Subsystem (`output_subsystem.v`)**: Writes the compressed Zstd frame back to system memory via an AXI write channel.

## Simulation and Performance Analysis

### Running the Hardware Testbench
The Verilog testbench simulates the compression of a highly compressible 256-byte data block to verify the DP engine, backtracker, and entropy encoder.

**Requirements:** `iverilog`

```bash
iverilog -g2012 -o zstd_sim \
    zstd_tb.v zstd.v input_subsystem.v rolling_hash_gen.v \
    bloom_filter.v cam_array.v tree_walkers.v topk_heap.v \
    price_calculator.v dp_engine.v backtracker.v \
    stats_collector.v entropy_encoder.v output_subsystem.v

vvp zstd_sim
