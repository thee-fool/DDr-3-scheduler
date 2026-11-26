#!/usr/bin/env python3
"""
golden_model.py  -  cycle-accurate Python reference model of the DDR3 scheduler

It reads the stimulus file, plays the same requests as the RTL and writes:
    golden_trace.txt : every command the scheduler must issue, with its cycle
                       ("cycle cmd bank addr"), then an end marker (cmd = 7)
                       and one last line with the four performance counters
    golden_rsp.txt   : every read response ("cycle id data")
The testbench compares the RTL against these two files cycle by cycle.
It also prints the performance numbers for the report.

The model follows the same rules as the RTL but is written differently on
purpose: the RTL uses down-counters, the model remembers WHEN each command
happened and checks "now - then >= delay". A slip in one of them shows up as
a mismatch instead of going unnoticed.

Cycle numbering: cycle 0 is the first clock cycle after reset. A command
chosen in cycle d is visible on the command bus in cycle d + 1 (the RTL
registers its outputs), so d + 1 is what the trace file contains.

Example:
    python3 golden_model.py --stim stim.txt
"""
import argparse

# ----------------------------------------------------------------------------
# DDR3-1600 11-11-11 numbers. They MUST match dram_params.vh.
# ----------------------------------------------------------------------------
tRCD, tRP, tRAS, tRC = 11, 11, 28, 39
tRRD, tFAW, tCCD     = 6, 32, 4
tWTR, tRTP, tWR      = 6, 6, 12
CL, CWL, BL2         = 11, 8, 4
tRFC                 = 128
MAX_POSTPONE         = 8
tWR2PRE = CWL + BL2 + tWR        # 24  WR -> PRE, same bank
tWR2RD  = CWL + BL2 + tWTR       # 18  WR -> RD
tRD2WR  = CL + tCCD + 2 - CWL    #  9  RD -> WR

QUEUE_DEPTH, WBUF_SLOTS = 16, 16

NOP, ACT, RD, WR, PRE, REF, END = 0, 1, 2, 3, 4, 5, 7
FCFS = 0
IDLE, CLOSE, DOREF = 0, 1, 2          # states of the refresh sequence
LONG_AGO = -10**9                     # "this never happened"


def decode(addr, amap):
    """Split a byte address into (row, bank, col). Same as addr_decode.v."""
    row = (addr >> 14) & 0x3FFF
    if amap == 0:                             # row : bank : col
        bank = (addr >> 11) & 0x7
        col  = ((addr >> 4) & 0x7F) << 3
    else:                                     # row : col : bank
        bank = (addr >> 4) & 0x7
        col  = ((addr >> 7) & 0x7F) << 3
    return row, bank, col


def default_data(row, bank, col):
    """What a memory location holds before anybody wrote to it.
    Same pattern as in dram_beh.v: a 32-bit word made from the location,
    repeated four times."""
    word = (0b10101 << 27) | (row << 13) | (bank << 10) | col
    return word | (word << 32) | (word << 64) | (word << 96)


class Bank:
    """What we remember about one bank."""
    def __init__(self):
        self.open  = False        # is a row open?
        self.row   = 0            # which one
        self.t_act = LONG_AGO     # cycle of the last ACT / PRE / RD / WR
        self.t_pre = LONG_AGO
        self.t_rd  = LONG_AGO
        self.t_wr  = LONG_AGO
        self.fresh = False        # opened, but not used yet (for hit counting)


class Model:
    def __init__(self, mode, amap, cap, trefi):
        self.mode, self.amap, self.cap, self.trefi = mode, amap, cap, trefi
        self.banks   = [Bank() for _ in range(8)]
        self.queue   = []              # waiting requests, oldest first
        self.cap_cnt = [0] * 8         # overtakes per bank (FR-FCFS+Cap)
        # last time of each kind of command, on any bank
        self.acts    = []              # cycles of all ACTs (for tRRD and tFAW)
        self.t_cas = self.t_rd = self.t_wr = self.t_ref = LONG_AGO
        # refresh
        self.refi_cnt, self.owed, self.ref_state = 0, 0, IDLE
        # write-buffer slots still held by writes that already left the queue
        self.slot_busy_until = []
        # data and results
        self.mem   = {}                # (row, bank, col) -> 128-bit data
        self.trace = []                # (bus cycle, cmd, bank, addr)
        self.rsps  = []                # (cycle, id, data)
        self.lat   = []                # latency of every finished request
        self.hits = self.conflicts = self.cmds = self.refs = 0
        self.ref_blocked = 0           # cycles lost to refresh

    # ---- timing questions: "may this command go in cycle `now`?" -----------
    def bank_act_ok(self, b, now):
        return now - b.t_pre >= tRP and now - b.t_act >= tRC

    def bank_cas_ok(self, b, now):
        return now - b.t_act >= tRCD

    def bank_pre_ok(self, b, now):
        return (now - b.t_act >= tRAS and now - b.t_rd >= tRTP
                and now - b.t_wr >= tWR2PRE)

    def ref_ok(self, now):
        return now - self.t_ref >= tRFC

    def glob_act_ok(self, now):
        rrd = (not self.acts) or now - self.acts[-1] >= tRRD
        faw = len(self.acts) < 4 or now - self.acts[-4] >= tFAW   # 4th-last ACT
        return rrd and faw and self.ref_ok(now)

    def glob_rd_ok(self, now):
        return now - self.t_cas >= tCCD and now - self.t_wr >= tWR2RD

    def glob_wr_ok(self, now):
        return now - self.t_cas >= tCCD and now - self.t_rd >= tRD2WR

    # ---- the scheduling policy ---------------------------------------------
    def choose(self, now):
        """Return (queue position, command) for this cycle, or None."""
        if self.ref_state != IDLE:
            return None                        # refresh blocks normal commands
        # FCFS: only the oldest request may do anything
        players = self.queue[:1] if self.mode == FCFS else self.queue
        cap_on  = self.mode >= 2

        # Pass 1: hit / conflict, and the hits that must wait (cap)
        info = []                              # per entry: (kind, may_go)
        seen_hit, seen_conf = set(), set()     # banks with an older hit/conflict
        keep_open = set()                      # banks whose open row is needed
        for e in players:
            bk, b = e["bank"], self.banks[e["bank"]]
            if not b.open:
                info.append(("closed", True))
            elif b.row == e["row"]:
                bypass = bk in seen_conf       # would overtake an older conflict
                capped = cap_on and bypass and self.cap_cnt[bk] >= self.cap
                first  = bk not in seen_hit    # oldest hit of this bank
                if not capped:
                    keep_open.add(bk)
                seen_hit.add(bk)
                e["bypass"] = bypass
                info.append(("hit", first and not capped))
            else:
                seen_conf.add(bk)
                info.append(("conflict", True))

        # Pass 2: the oldest row hit whose RD/WR may go now
        for i, e in enumerate(players):
            kind, may_go = info[i]
            b = self.banks[e["bank"]]
            if kind == "hit" and may_go and self.bank_cas_ok(b, now):
                if e["we"] and self.glob_wr_ok(now):
                    return i, WR
                if not e["we"] and self.glob_rd_ok(now):
                    return i, RD

        # Pass 3: otherwise the oldest entry that can open or close a row
        for i, e in enumerate(players):
            kind, _ = info[i]
            b = self.banks[e["bank"]]
            if kind == "closed" and self.bank_act_ok(b, now) and self.glob_act_ok(now):
                return i, ACT
            if kind == "conflict" and e["bank"] not in keep_open and self.bank_pre_ok(b, now):
                return i, PRE
        return None

    # ---- one clock cycle ----------------------------------------------------
    def step(self, now, offered):
        """Simulate cycle `now`. `offered` is the request the host presents in
        this cycle (or None). Returns True if that request was accepted."""
        # Everything below is decided from the state at the START of the cycle.
        queue_empty = not self.queue
        any_open    = any(b.open for b in self.banks)
        all_pre_ok  = all(self.bank_pre_ok(b, now) for b in self.banks if b.open)
        all_act_ok  = all(self.bank_act_ok(b, now) for b in self.banks)

        # refresh engine
        tick    = self.refi_cnt == self.trefi - 1
        want    = (self.owed != 0 and queue_empty) or self.owed >= MAX_POSTPONE
        do_prea = self.ref_state == CLOSE and any_open and all_pre_ok
        do_ref  = self.ref_state == DOREF and all_act_ok and self.ref_ok(now)
        if self.ref_state != IDLE or not self.ref_ok(now):
            self.ref_blocked += 1

        # normal scheduling
        pick = self.choose(now)

        # can the host's request be accepted?
        slots = (sum(e["we"] for e in self.queue)
                 + sum(1 for t in self.slot_busy_until if now <= t))
        ready    = len(self.queue) < QUEUE_DEPTH and slots < WBUF_SLOTS
        accepted = offered is not None and ready

        # ---- now apply everything (this is the clock edge) -----------------
        if do_prea:
            self.emit(now, PRE, 0, 0x400)                 # address bit 10 = all banks
            for b in self.banks:
                b.open, b.t_pre = False, now
        elif do_ref:
            self.emit(now, REF, 0, 0)
            self.t_ref = now
            self.refs += 1
        elif pick is not None:
            i, cmd = pick
            e  = self.queue[i]
            bk = e["bank"]
            b  = self.banks[bk]
            if cmd == ACT:
                self.emit(now, ACT, bk, e["row"])
                b.open, b.row, b.t_act, b.fresh = True, e["row"], now, True
                self.acts.append(now)
                self.cap_cnt[bk] = 0
            elif cmd == PRE:
                self.emit(now, PRE, bk, 0)
                b.open, b.t_pre = False, now
                self.conflicts += 1
            else:                                         # RD or WR: request done
                self.emit(now, cmd, bk, e["col"])
                self.t_cas = now
                if not b.fresh:
                    self.hits += 1
                b.fresh = False
                if e.get("bypass"):
                    self.cap_cnt[bk] = min(15, self.cap_cnt[bk] + 1)
                key = (e["row"], bk, e["col"])
                if cmd == WR:
                    b.t_wr = self.t_wr = now
                    self.mem[key] = e["wdata"]
                    self.slot_busy_until.append(now + CWL)
                    last_beat = now + 1 + CWL + BL2 - 1   # last write beat on the bus
                else:
                    b.t_rd = self.t_rd = now
                    data = self.mem.get(key, default_data(*key))
                    last_beat = now + 1 + CL + BL2 - 1    # last read beat on the bus
                    self.rsps.append((last_beat + 1, e["id"], data))
                self.lat.append(last_beat - e["t_accept"])
                del self.queue[i]                         # younger entries move down

        if accepted:
            row, bank, col = decode(offered["addr"], self.amap)
            self.queue.append(dict(row=row, bank=bank, col=col, we=offered["we"],
                                   id=offered["id"], wdata=offered["wdata"],
                                   t_accept=now))

        # refresh bookkeeping
        self.refi_cnt = 0 if tick else self.refi_cnt + 1
        if tick and not do_ref:
            self.owed = min(15, self.owed + 1)
        elif do_ref and not tick:
            self.owed -= 1
        if self.ref_state == IDLE:
            if want:
                self.ref_state = CLOSE
        elif self.ref_state == CLOSE:
            if not any_open or do_prea:
                self.ref_state = DOREF
        elif do_ref:
            self.ref_state = IDLE
        return accepted

    def emit(self, now, cmd, bank, addr):
        self.trace.append((now + 1, cmd, bank, addr))     # on the bus one cycle later
        self.cmds += 1


def run(stim_path, trace_path, rsp_path):
    # ---- read the stimulus file ---------------------------------------------
    with open(stim_path) as f:
        mode, amap, cap, trefi, nreq = (int(x) for x in f.readline().split())
        reqs = []
        for line in f:
            gap, we, rid, addr, wdata = line.split()
            reqs.append(dict(gap=int(gap), we=int(we), id=int(rid),
                             addr=int(addr, 16), wdata=int(wdata, 16)))
    assert len(reqs) == nreq, "stimulus file is incomplete"

    m = Model(mode, amap, cap, trefi)
    nxt, offer_at = 0, reqs[0]["gap"]      # next request and the cycle it is offered
    now, done_at = 0, None
    while True:
        offered = reqs[nxt] if nxt < nreq and now >= offer_at else None
        if m.step(now, offered):
            nxt += 1
            if nxt < nreq:
                offer_at = now + 1 + reqs[nxt]["gap"]
        now += 1
        # stop 30 cycles after the last request and its data are finished
        if nxt == nreq and not m.queue and done_at is None:
            done_at = max([now] + [r[0] for r in m.rsps]) + 30
        if done_at is not None and now >= done_at:
            break
    end = now          # commands chosen in cycles 0 .. end-1 were simulated

    # ---- write the golden files ---------------------------------------------
    with open(trace_path, "w") as f:
        for cyc, cmd, bank, addr in m.trace:
            f.write(f"{cyc} {cmd} {bank} {addr:04x}\n")
        f.write(f"{end} {END} 0 0000\n")
        f.write(f"{m.hits} {m.conflicts} {m.cmds} {m.refs}\n")
    with open(rsp_path, "w") as f:
        for cyc, rid, data in m.rsps:
            f.write(f"{cyc} {rid} {data:032x}\n")

    # ---- performance numbers -------------------------------------------------
    return dict(mode=mode, map=amap, cap=cap, requests=nreq, cycles=end,
                hit_rate=100.0 * m.hits / nreq,
                avg_lat=sum(m.lat) / len(m.lat), max_lat=max(m.lat),
                bus_util=100.0 * nreq * BL2 / end,
                ref_ovh=100.0 * m.ref_blocked / end,
                hits=m.hits, conflicts=m.conflicts, cmds=m.cmds, refs=m.refs)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Golden model of the DDR3 scheduler")
    ap.add_argument("--stim",  default="stim.txt")
    ap.add_argument("--trace", default="golden_trace.txt")
    ap.add_argument("--rsp",   default="golden_rsp.txt")
    ap.add_argument("--csv",   action="store_true", help="print one CSV line instead of text")
    a = ap.parse_args()
    r = run(a.stim, a.trace, a.rsp)
    if a.csv:
        print(f"{r['mode']},{r['map']},{r['cap']},{r['requests']},{r['cycles']},"
              f"{r['hit_rate']:.1f},{r['avg_lat']:.1f},{r['max_lat']},"
              f"{r['bus_util']:.1f},{r['ref_ovh']:.2f}")
    else:
        names = {0: "FCFS", 1: "FR-FCFS", 2: "FR-FCFS+Cap", 3: "FR-FCFS+Cap"}
        print(f"policy            : {names[r['mode']]}   (address map {r['map']}, cap {r['cap']})")
        print(f"requests / cycles : {r['requests']} / {r['cycles']}")
        print(f"row-hit rate      : {r['hit_rate']:.1f} %")
        print(f"latency avg / max : {r['avg_lat']:.1f} / {r['max_lat']} cycles")
        print(f"data-bus use      : {r['bus_util']:.1f} %")
        print(f"refresh overhead  : {r['ref_ovh']:.2f} %")
        print(f"counters          : hits={r['hits']} conflicts={r['conflicts']} "
              f"cmds={r['cmds']} refs={r['refs']}")
