nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ gcc -O2 -o zstd_file_compare zstd_file_compare.c -lzstd
nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ head -c 200 /usr/share/dict/words > test_200k.txt
nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ ./zstd_file_compare test_200k.txt

=================================================================
  Compiling Verilog Design for File Testing...
=================================================================
  Running RTL Simulation on: test_200k.txt
-----------------------------------------------------------------
[58000 ns] Starting compression...

=================================================================
  RESULTS
=================================================================
  Source bytes   : 200
  Compressed     : 114
  HW cycles used : 1509
=================================================================

zstd_file_tb.v:235: $finish called at 6094000 (1ps)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DYNAMIC HARDWARE vs SOFTWARE RESULT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  File Tested      : test_200k.txt
  HW cycles used   : 1509 
  SW L22 cycles    : 21982 
  HW compressed    : 114 bytes (1.75:1 Ratio)
  SW L22 compressed: 125 bytes (1.60:1 Ratio)

  Throughput projection at 500 MHz:
  HW Latency       : 0.003 ms
  HW Throughput    : 63.20 MB/s
nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ head -c 2000 /usr/share/dict/words > test_200k.txt
nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ ./zstd_file_compare test_200k.txt

=================================================================
  Compiling Verilog Design for File Testing...
=================================================================
  Running RTL Simulation on: test_200k.txt
-----------------------------------------------------------------
[58000 ns] Starting compression...
[19998000 ns] Heartbeat: cycle 5000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[39998000 ns] Heartbeat: cycle 10000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)

=================================================================
  RESULTS
=================================================================
  Source bytes   : 2000
  Compressed     : 1178
  HW cycles used : 12339
=================================================================

zstd_file_tb.v:235: $finish called at 49414000 (1ps)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DYNAMIC HARDWARE vs SOFTWARE RESULT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  File Tested      : test_200k.txt
  HW cycles used   : 12339 
  SW L22 cycles    : 183622 
  HW compressed    : 1178 bytes (1.70:1 Ratio)
  SW L22 compressed: 792 bytes (2.53:1 Ratio)

  Throughput projection at 500 MHz:
  HW Latency       : 0.025 ms
  HW Throughput    : 77.29 MB/s
nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ head -c 20000 /usr/share/dict/words > test_200k.txt
nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ ./zstd_file_compare test_200k.txt

=================================================================
  Compiling Verilog Design for File Testing...
=================================================================
  Running RTL Simulation on: test_200k.txt
-----------------------------------------------------------------
[58000 ns] Starting compression...
[19998000 ns] Heartbeat: cycle 5000, FSM State = 2 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[39998000 ns] Heartbeat: cycle 10000, FSM State = 2 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[59998000 ns] Heartbeat: cycle 15000, FSM State = 2 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[79998000 ns] Heartbeat: cycle 20000, FSM State = 2 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[99998000 ns] Heartbeat: cycle 25000, FSM State = 2 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
^C
nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ head -c 16000 /usr/share/dict/words > test_200k.txt
nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ ./zstd_file_compare test_200k.txt

=================================================================
  Compiling Verilog Design for File Testing...
=================================================================
  Running RTL Simulation on: test_200k.txt
-----------------------------------------------------------------
[58000 ns] Starting compression...
[19998000 ns] Heartbeat: cycle 5000, FSM State = 2 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[39998000 ns] Heartbeat: cycle 10000, FSM State = 2 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[59998000 ns] Heartbeat: cycle 15000, FSM State = 2 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[79998000 ns] Heartbeat: cycle 20000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[99998000 ns] Heartbeat: cycle 25000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[119998000 ns] Heartbeat: cycle 30000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[139998000 ns] Heartbeat: cycle 35000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[159998000 ns] Heartbeat: cycle 40000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[179998000 ns] Heartbeat: cycle 45000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[199998000 ns] Heartbeat: cycle 50000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[219998000 ns] Heartbeat: cycle 55000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[239998000 ns] Heartbeat: cycle 60000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[259998000 ns] Heartbeat: cycle 65000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[279998000 ns] Heartbeat: cycle 70000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[299998000 ns] Heartbeat: cycle 75000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[319998000 ns] Heartbeat: cycle 80000, FSM State = 3 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[339998000 ns] Heartbeat: cycle 85000, FSM State = 5 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[359998000 ns] Heartbeat: cycle 90000, FSM State = 5 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)
[379998000 ns] Heartbeat: cycle 95000, FSM State = 5 (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)

=================================================================
  RESULTS
=================================================================
  Source bytes   : 16000
  Compressed     : 9258
  HW cycles used : 96554
=================================================================

zstd_file_tb.v:235: $finish called at 386274000 (1ps)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DYNAMIC HARDWARE vs SOFTWARE RESULT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  File Tested      : test_200k.txt
  HW cycles used   : 96554 
  SW L22 cycles    : 2518491 
  HW compressed    : 9258 bytes (1.73:1 Ratio)
  SW L22 compressed: 4629 bytes (3.46:1 Ratio)

  Throughput projection at 500 MHz:
  HW Latency       : 0.193 ms
  HW Throughput    : 79.02 MB/s
nishan@fedora:~/Documents/RISCV_acceleration_zstd/comp$ 
