#!/usr/bin/env python3
"""
traffic_gen.py  -  writes the stimulus file (the list of requests for one test)

The SAME file is read by the Verilog testbench (tb_top.v) and by the Python
golden model (golden_model.py), so both see exactly the same traffic.

File format (plain text):
    line 1 :  mode  map  cap  trefi  nreq          <- test configuration
    then one line per request:
              gap  we  id  addr(hex)  wdata(hex)
      gap   = idle cycles before this request is offered
      we    = 1 write, 0 read
      id    = 4-bit tag (0..15, simply counted up)
      addr  = 28-bit byte address, aligned to 16 bytes (one burst)
      wdata = 128-bit write data (random; unused for reads)

Traffic patterns:
    stream : sequential 16-byte steps. With --streams N there are N such
             streams far apart in memory, taken in turn (like a copy loop that
             reads one array and writes another).
    stride : one stream that jumps --stride bytes each time.
    random : uniformly random addresses over the whole 256 MB.

Example:
    python3 traffic_gen.py --pattern stream --mode 1 --n 500 --out stim.txt
"""
import argparse
import random

ADDR_MASK = (1 << 28) - 1          # 28-bit address space (256 MB)


def main():
    ap = argparse.ArgumentParser(description="Make a stimulus file for the DDR3 scheduler")
    ap.add_argument("--pattern", choices=["stream", "stride", "random"], default="stream")
    ap.add_argument("--mode",    type=int, default=1, help="0 FCFS, 1 FR-FCFS, 2 FR-FCFS+Cap")
    ap.add_argument("--map",     type=int, default=0, help="0 row:bank:col, 1 row:col:bank")
    ap.add_argument("--cap",     type=int, default=4, help="cap_limit, 0..15 (used in mode 2)")
    ap.add_argument("--trefi",   type=int, default=6240, help="refresh interval in cycles")
    ap.add_argument("--n",       type=int, default=1000, help="number of requests")
    ap.add_argument("--wr-pct",  type=int, default=30, help="percentage of writes, 0..100")
    ap.add_argument("--gap",     type=int, default=0, help="idle cycles between requests")
    ap.add_argument("--streams", type=int, default=2, help="number of streams (stream pattern)")
    ap.add_argument("--stride",  type=int, default=4096, help="step in bytes (stride pattern)")
    ap.add_argument("--seed",    type=int, default=1)
    ap.add_argument("--out",     default="stim.txt")
    a = ap.parse_args()

    rng = random.Random(a.seed)

    # Each stream starts 64 MB after the previous one, so the streams use
    # different rows (and would fight for the same bank under FCFS).
    stream_pos = [(s * 0x4000000) & ADDR_MASK for s in range(a.streams)]
    stride_pos = 0

    with open(a.out, "w") as f:
        f.write(f"{a.mode} {a.map} {a.cap} {a.trefi} {a.n}\n")
        for i in range(a.n):
            if a.pattern == "stream":
                s = i % a.streams                       # take the streams in turn
                addr = stream_pos[s]
                stream_pos[s] = (addr + 16) & ADDR_MASK
            elif a.pattern == "stride":
                addr = stride_pos
                stride_pos = (addr + a.stride) & ADDR_MASK
            else:
                addr = rng.randrange(1 << 28)

            addr &= ~0xF                                # align to one burst
            we    = 1 if rng.randrange(100) < a.wr_pct else 0
            wdata = rng.getrandbits(128)
            # the first request waits a few cycles after reset
            gap   = 5 if i == 0 else a.gap
            f.write(f"{gap} {we} {i % 16} {addr:07x} {wdata:032x}\n")


if __name__ == "__main__":
    main()
