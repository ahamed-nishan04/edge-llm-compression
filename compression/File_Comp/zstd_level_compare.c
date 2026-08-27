#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <zstd.h>

static const double HW_FREQ_MHZ[] = { 250.0, 500.0, 800.0, 1000.0 };
#define N_HW_FREQS  (int)(sizeof(HW_FREQ_MHZ) / sizeof(HW_FREQ_MHZ[0]))

static void build_dataset(uint8_t *buf, int size)
{
    int i;
    if (size == 512) {
        uint32_t lcg = 0x1234ABCDu;
        for (i = 0;   i < 128; i++) buf[i] = 0x00;
        for (i = 128; i < 192; i++) buf[i] = 0x00;
        for (i = 192; i < 256; i++) buf[i] = (uint8_t)(0x01 + (i - 192) % 4);
        for (i = 256; i < 320; i++) buf[i] = (uint8_t)(0x01 + (i - 256) % 4);
        for (i = 320; i < 384; i++) buf[i] = (uint8_t)(0x20 + ((i - 320) * 7 + 3) % 96);
        for (i = 384; i < 448; i++) {
            lcg = lcg * 1664525u + 1013904223u;
            buf[i] = (uint8_t)(0x24);
        }
        for (i = 448; i < 480; i++) buf[i] = (i % 2 == 0) ? 0xDE : 0xAD;
        for (i = 480; i < 512; i++) {
            int pos = (i - 480) % 4;
            int idx = (i - 480) / 4;
            switch (pos) {
                case 0: buf[i] = 0x5A; break;
                case 1: buf[i] = 0xA5; break;
                case 2: buf[i] = (uint8_t)idx; break;
                case 3: buf[i] = (uint8_t)(~idx); break;
            }
        }
    } else if (size == 256) {
        for (i = 0;   i < 64;  i++) buf[i] = 0x00;
        for (i = 64;  i < 96;  i++) buf[i] = 0x41 + ((i - 64) % 8);
        for (i = 96;  i < 128; i++) buf[i] = 0x00;
        for (i = 128; i < 192; i++) buf[i] = 0x41 + ((i - 128) % 8);
        for (i = 192; i < 224; i++) buf[i] = (i % 2 == 0) ? 0xAB : 0xCD;
        for (i = 224; i < 256; i++) buf[i] = 0xFF;
    } else {
        memset(buf, 0, size);
    }
}

static size_t safe_compress(ZSTD_CCtx* cctx, const uint8_t *src, size_t src_len,
                            uint8_t *dst, size_t dst_cap, int level)
{
    size_t c = ZSTD_compressCCtx(cctx, dst, dst_cap, src, src_len, level);
    if (ZSTD_isError(c)) {
        fprintf(stderr, "\n[!] ZSTD_compress error at level %d: %s\n", level, ZSTD_getErrorName(c));
        exit(EXIT_FAILURE);
    }
    return c;
}

static double elapsed_ns(struct timespec t0, struct timespec t1)
{
    return (double)(t1.tv_sec  - t0.tv_sec)  * 1e9 + (double)(t1.tv_nsec - t0.tv_nsec);
}

static double estimate_cpu_mhz(void)
{
    struct timespec t0, t1;
    volatile uint64_t sum = 0; 
    const uint64_t ITERS = 10000000ULL;
    
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (uint64_t k = 0; k < ITERS; k++) sum += k;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    
    (void)sum;
    return (ITERS * 2.0) / (elapsed_ns(t0, t1) / 1000.0); 
}

static const char *level_strategy(int level)
{
    if (level <= 2)  return "fast";
    if (level <= 4)  return "dfast";
    if (level <= 6)  return "greedy";
    if (level <= 9)  return "lazy";
    if (level <= 12) return "lazy2";
    if (level <= 15) return "btlazy2";
    if (level <= 17) return "btopt";
    if (level <= 19) return "btultra";
    return                  "btultra2";
}

int main(void)
{
    int hw_src_bytes = 0;
    int hw_comp_bytes = 0;
    int hw_cycles = 0;
    long long hw_finish_time = 0;

    printf("\n=================================================================\n");
    printf("  Compiling Verilog Design...\n");
    printf("=================================================================\n");
    
    int compile_status = system("iverilog -g2012 -o zstd_sim zstd_tb.v zstd.v input_subsystem.v rolling_hash_gen.v bloom_filter.v cam_array.v tree_walkers.v topk_heap.v price_calculator.v dp_engine.v backtracker.v stats_collector.v entropy_encoder.v output_subsystem.v");
    
    if (compile_status != 0) {
        fprintf(stderr, "Error: iverilog compilation failed.\n");
        return EXIT_FAILURE;
    }

    printf("  Running Simulation & Extracting Data...\n");
    printf("-----------------------------------------------------------------\n");

    FILE *fp = popen("vvp zstd_sim", "r");
    if (!fp) {
        perror("Failed to run vvp");
        return EXIT_FAILURE;
    }

    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        printf("%s", line); 
        
        char *colon;
        if (strstr(line, "Source bytes") && (colon = strchr(line, ':'))) {
            hw_src_bytes = atoi(colon + 1);
        }
        else if (strstr(line, "Compressed") && (colon = strchr(line, ':'))) {
            hw_comp_bytes = atoi(colon + 1);
        }
        else if (strstr(line, "HW cycles used") && (colon = strchr(line, ':'))) {
            hw_cycles = atoi(colon + 1);
        }
        else if (strstr(line, "$finish called at")) {
            sscanf(line, "%*[^$]$finish called at %lld", &hw_finish_time);
        }
    }
    pclose(fp);

    if (hw_cycles == 0 && hw_finish_time > 0) {
        hw_cycles = (int)((hw_finish_time - 58000) / 4000);
    }

    if (hw_src_bytes <= 0) {
        fprintf(stderr, "\n[!] Error: Could not parse source size from simulation.\n");
        return EXIT_FAILURE;
    }

    uint8_t *src = malloc(hw_src_bytes);
    if (!src) { perror("malloc"); return EXIT_FAILURE; }
    build_dataset(src, hw_src_bytes);

    size_t   dst_cap = ZSTD_compressBound(hw_src_bytes);
    uint8_t *dst     = malloc(dst_cap);
    if (!dst) { perror("malloc"); return EXIT_FAILURE; }

    int    min_lvl = 1;   
    int    max_lvl = 22;   
    int    n_levels = max_lvl - min_lvl + 1;  

    size_t *sw_comp        = calloc(n_levels, sizeof(size_t));
    double *sw_ns_per_call = calloc(n_levels, sizeof(double));

    ZSTD_CCtx* cctx = ZSTD_createCCtx();
    if (!cctx) {
        fprintf(stderr, "Failed to create ZSTD context\n");
        return EXIT_FAILURE;
    }

    printf("\n  Calibrating CPU frequency ...");
    fflush(stdout);
    double cpu_mhz = estimate_cpu_mhz();
    printf("  ~%.0f MHz\n\n", cpu_mhz);

    safe_compress(cctx, src, hw_src_bytes, dst, dst_cap, 1);

    printf("  Benchmarking levels 1 to 22...\n\n");

    for (int li = 0; li < n_levels; li++) {
        int level = min_lvl + li;
        
        printf("\r    -> Benchmarking Level %2d / %2d ... ", level, max_lvl);
        fflush(stdout);
        
        sw_comp[li] = safe_compress(cctx, src, hw_src_bytes, dst, dst_cap, level);

        int reps = 5000;
        if (level >= 10) reps = 500;
        if (level >= 16) reps = 50;
        if (level >= 19) reps = 5; 

        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int r = 0; r < reps; r++) {
            safe_compress(cctx, src, hw_src_bytes, dst, dst_cap, level);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);

        sw_ns_per_call[li] = elapsed_ns(t0, t1) / (double)reps;
    }
    
    printf("\r    -> Benchmarking Complete.          \n\n");

    ZSTD_freeCCtx(cctx);

    printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    printf("  SOFTWARE COMPRESSION  (%d bytes input)\n", hw_src_bytes);
    printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    printf("  %-5s  %-7s  %-8s  %-7s  %-8s  %-10s  %-13s  %s\n",
           "Level", "Cmp(B)", "Saved(B)", "Ratio", "Time/µs", "Cycles*", "GB/s", "Strategy");
    printf("  %-5s  %-7s  %-8s  %-7s  %-8s  %-10s  %-13s  %s\n",
           "-----", "-------", "--------", "-------", "--------", "----------", "-------------", "---------");

    for (int li = 0; li < n_levels; li++) {
        int    level  = min_lvl + li;
        size_t comp   = sw_comp[li];
        int    saved  = hw_src_bytes - (int)comp;
        double ratio  = (double)hw_src_bytes / (double)comp;
        double us     = sw_ns_per_call[li] / 1000.0;
        double cycles = sw_ns_per_call[li] * cpu_mhz / 1000.0;
        double gbps   = (double)hw_src_bytes / sw_ns_per_call[li]; 

        printf("  %-5d  %-7zu  %-8d  %-7.3f  %-8.3f  %-10.0f  %-13.6f  %s\n",
               level, comp, saved, ratio, us, cycles, gbps,
               level_strategy(level));
    }

    printf("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    printf("  DYNAMIC HARDWARE RESULT\n");
    printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    
    printf("  HW cycles used   : %d \n", hw_cycles);
    printf("  HW compressed    : %d bytes (%.2f:1 Ratio)\n", hw_comp_bytes, (double)hw_src_bytes / hw_comp_bytes);
    printf("  SW L22 Proxy     : %zu bytes \n\n", sw_comp[n_levels - 1]);

    printf("  Throughput projection at tape-out frequencies:\n");
    printf("  %-14s  %-14s  %-16s  %-14s\n", "Clock (MHz)", "Period (ns)", "Latency (µs)", "Throughput");
    printf("  %-14s  %-14s  %-16s  %-14s\n", "-----------", "----------", "------------", "----------");
           
    for (int f = 0; f < N_HW_FREQS; f++) {
        double freq_mhz  = HW_FREQ_MHZ[f];
        double period_ns = 1000.0 / freq_mhz;
        double lat_us    = (hw_cycles * period_ns) / 1000.0;
        double gbps      = ((double)hw_src_bytes / lat_us) / 1000.0;
        printf("  %-14.0f  %-14.2f  %-16.3f  %.5f GB/s\n", freq_mhz, period_ns, lat_us, gbps);
    }

    printf("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    printf("  HW vs SW SPEED  (hardware projected at 500 MHz)\n");
    printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    printf("  %-14s  %-12s  %-12s  %s\n", "Impl.", "Latency", "GB/s", "HW speedup");
    printf("  %-14s  %-12s  %-12s  %s\n", "--------------", "--------", "-------", "----------");

    double hw_lat_us_500 = (hw_cycles * (1000.0 / 500.0)) / 1000.0;
    double hw_gbps_500   = ((double)hw_src_bytes / hw_lat_us_500) / 1000.0;

    int show_levels[] = {1, 3, 5, 7, 10, 15, 19, 22};
    int n_show = (int)(sizeof(show_levels) / sizeof(show_levels[0]));
    
    for (int si = 0; si < n_show; si++) {
        int lvl = show_levels[si];
        int li  = lvl - min_lvl;
        double sw_lat_us = sw_ns_per_call[li] / 1000.0;
        double sw_gbps   = ((double)hw_src_bytes / sw_lat_us) / 1000.0;
        double speedup   = sw_lat_us / hw_lat_us_500;
        printf("  SW level %-5d  %-8.3f µs   %-12.5f  %.1f× %s SW L%d\n",
               lvl, sw_lat_us, sw_gbps, speedup,
               speedup >= 1.0 ? "faster than" : "slower  than", lvl);
    }
    printf("  HW @ 500 MHz   %-8.3f µs   %-12.5f  (reference)\n", hw_lat_us_500, hw_gbps_500);

    free(src);
    free(dst);
    free(sw_comp);
    free(sw_ns_per_call);
    return EXIT_SUCCESS;
}
