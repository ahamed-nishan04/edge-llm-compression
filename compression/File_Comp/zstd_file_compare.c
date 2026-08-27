#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>
#include <zstd.h>

static const double HW_FREQ_MHZ[] = { 250.0, 500.0, 800.0, 1000.0 };
#define N_HW_FREQS  (int)(sizeof(HW_FREQ_MHZ) / sizeof(HW_FREQ_MHZ[0]))

static const int SW_LEVELS[] = { 1, 10, 22 };
#define N_SW_LEVELS (int)(sizeof(SW_LEVELS) / sizeof(SW_LEVELS[0]))

static double elapsed_ns(struct timespec t0, struct timespec t1) {
    return (double)(t1.tv_sec  - t0.tv_sec)  * 1e9 + (double)(t1.tv_nsec - t0.tv_nsec);
}

static double estimate_cpu_mhz(void) {
    struct timespec t0, t1;
    volatile uint64_t sum = 0;
    const uint64_t ITERS = 10000000ULL;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (uint64_t k = 0; k < ITERS; k++) sum += k;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    (void)sum;
    return (ITERS * 2.0) / (elapsed_ns(t0, t1) / 1000.0);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <path_to_test_file>\n", argv[0]);
        return EXIT_FAILURE;
    }

    const char *filepath = argv[1];

    FILE *f_in = fopen(filepath, "rb");
    if (!f_in) { perror("Failed to open input file"); return EXIT_FAILURE; }

    fseek(f_in, 0, SEEK_END);
    size_t file_size = ftell(f_in);
    fseek(f_in, 0, SEEK_SET);

    uint8_t *src = malloc(file_size);
    if (!src || fread(src, 1, file_size, f_in) != file_size) {
        fprintf(stderr, "Failed to read file into memory.\n");
        fclose(f_in);
        return EXIT_FAILURE;
    }
    fclose(f_in);

    int hw_src_bytes = 0;
    int hw_comp_bytes = 0;
    int hw_cycles = 0;

    printf("\n=================================================================\n");
    printf("  Compiling Verilog Design for File Testing...\n");
    printf("=================================================================\n");

    int compile_status = system(
        "iverilog -g2012 -o zstd_sim "
        "zstd_file_tb.v zstd.v input_subsystem.v rolling_hash_gen.v "
        "bloom_filter.v cam_array.v tree_walkers.v topk_heap.v "
        "price_calculator.v dp_engine.v backtracker.v stats_collector.v "
        "entropy_encoder.v output_subsystem.v");

    if (compile_status != 0) { free(src); return EXIT_FAILURE; }

    printf("  Running RTL Simulation on: %s\n", filepath);
    printf("-----------------------------------------------------------------\n");

    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "vvp zstd_sim +SRC_FILE=\"%s\"", filepath);

    FILE *fp = popen(cmd, "r");
    if (!fp) { perror("Failed to run vvp"); free(src); return EXIT_FAILURE; }

    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        printf("%s", line);
        char *colon;
        if      (strstr(line, "Source bytes")  && (colon = strchr(line, ':'))) hw_src_bytes  = atoi(colon + 1);
        else if (strstr(line, "Compressed")    && (colon = strchr(line, ':'))) hw_comp_bytes = atoi(colon + 1);
        else if (strstr(line, "HW cycles used")&& (colon = strchr(line, ':'))) hw_cycles     = atoi(colon + 1);
    }
    pclose(fp);

    double cpu_mhz = estimate_cpu_mhz();
    size_t dst_cap = ZSTD_compressBound(file_size);
    uint8_t *dst   = malloc(dst_cap);
    if (!dst) { fprintf(stderr, "malloc failed\n"); free(src); return EXIT_FAILURE; }

    size_t sw_comp[N_SW_LEVELS];
    double sw_ns  [N_SW_LEVELS];

    ZSTD_CCtx *cctx = ZSTD_createCCtx();
    for (int i = 0; i < N_SW_LEVELS; i++) {
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        sw_comp[i] = ZSTD_compressCCtx(cctx, dst, dst_cap, src, file_size, SW_LEVELS[i]);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        sw_ns[i] = elapsed_ns(t0, t1);
    }
    ZSTD_freeCCtx(cctx);

    printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    printf("  DYNAMIC HARDWARE vs SOFTWARE RESULT\n");
    printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    printf("  File Tested        : %s\n", filepath);
    printf("  Input size         : %zu bytes\n\n", file_size);

    double hw_ratio = (hw_comp_bytes > 0) ? (double)hw_src_bytes / hw_comp_bytes : 0.0;
    printf("  %-20s  %8d bytes  ratio %5.2f:1  cycles %10d\n", "HW (RTL sim)", hw_comp_bytes, hw_ratio, hw_cycles);

    for (int i = 0; i < N_SW_LEVELS; i++) {
        double ratio  = (sw_comp[i] > 0) ? (double)file_size / (double)sw_comp[i] : 0.0;
        double cycles = (sw_ns[i] / 1000.0) * cpu_mhz;
        char label[32];
        snprintf(label, sizeof(label), "SW L%-2d (zstd)", SW_LEVELS[i]);
        printf("  %-20s  %8zu bytes  ratio %5.2f:1  cycles %10.0f\n", label, sw_comp[i], ratio, cycles);
    }

    printf("\n  Throughput projection at 500 MHz (HW):\n");
    printf("  HW Latency         : %.3f ms\n",   (hw_cycles * 2.0) / 1e6);
    printf("  HW Throughput      : %.2f MB/s\n", ((double)hw_src_bytes / 1048576.0) / ((hw_cycles * 2.0) / 1e9));

    printf("\n  Cycle speedup  HW vs SW:\n");
    for (int i = 0; i < N_SW_LEVELS; i++) {
        double sw_cycles = (sw_ns[i] / 1000.0) * cpu_mhz;
        printf("    vs L%-2d : %.1fx\n", SW_LEVELS[i], (hw_cycles > 0) ? sw_cycles / hw_cycles : 0.0);
    }

    free(src);
    free(dst);
    return EXIT_SUCCESS;
}
