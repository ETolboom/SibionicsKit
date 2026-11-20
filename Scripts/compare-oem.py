#!/usr/bin/env python3
"""Compare SibionicsKit logs with the official app's Excel export.

Usage:
    Scripts/compare-oem.py export.xlsx sibionics_log_*.txt [--csv out.csv]

Reads the `glucose time=… seq=… mmol=… mgdl=… -> decision` lines the driver
writes for every reading, and the official app's "Time / Sensor Reading
(mmol/L)" sheet, and lines them up by local minute. Standard library only.
"""

import argparse
import csv
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from datetime import datetime

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
FACTOR = 18.0182

GLUCOSE = re.compile(
    r"^\[(?P<logged>\S+) \w+\] .*?glucose time=(?P<time>\d{4}-\d\d-\d\d \d\d:\d\d) GMT\S* "
    r"seq=(?P<seq>\d+) mmol=(?P<mmol>\S+) mgdl=(?P<mgdl>\S+) trend=(?P<trend>\S+) "
    r"rate=(?P<rate>\S+) q=(?P<q>\d+) src=(?P<src>\w+) -> (?P<decision>.*)$"
)
RESEND = re.compile(r"engine: rx (live|cached) seq=(\d+) .*replay")
IGNORED = re.compile(r"ignoring history packet|history ack status \d+ detail \d+ \(no request")


def read_oem(path):
    with zipfile.ZipFile(path) as z:
        strings = []
        if "xl/sharedStrings.xml" in z.namelist():
            root = ET.fromstring(z.read("xl/sharedStrings.xml"))
            for si in root.findall("m:si", NS):
                strings.append("".join(t.text or "" for t in si.iter(f"{{{NS['m']}}}t")))
        sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
    readings = {}
    for row in sheet.iter(f"{{{NS['m']}}}row"):
        cells = []
        for c in row.findall("m:c", NS):
            v = c.find("m:v", NS)
            if v is None:
                cells.append(None)
            elif c.get("t") == "s":
                cells.append(strings[int(v.text)])
            else:
                cells.append(v.text)
        if len(cells) < 2 or not cells[0] or not cells[1]:
            continue
        stamp = re.sub(r"\s*GMT[+-]?\d*$", "", cells[0].strip())
        try:
            t = datetime.strptime(stamp, "%d-%m-%Y %H:%M")
            readings[t] = float(cells[1])
        except ValueError:
            continue  # header
    return readings


def read_logs(paths):
    rows, resends, ignored = [], [], 0
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = GLUCOSE.match(line)
                if m:
                    d = m.groupdict()
                    d["time"] = datetime.strptime(d["time"], "%Y-%m-%d %H:%M")
                    d["seq"] = int(d["seq"])
                    rows.append(d)
                    continue
                m = RESEND.search(line)
                if m:
                    resends.append((m.group(1), int(m.group(2))))
                if IGNORED.search(line):
                    ignored += 1
    return rows, resends, ignored


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xlsx")
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--csv", help="write a side-by-side table")
    args = ap.parse_args()

    oem = read_oem(args.xlsx)
    rows, resends, ignored = read_logs(args.logs)
    if not rows:
        sys.exit("no `glucose time=…` lines in the logs (logs from a build before the glucose log?)")

    forwarded = defaultdict(list)
    decisions = Counter()
    for r in rows:
        decisions[r["decision"].split(":")[0]] += 1
        if r["decision"] == "forwarded":
            forwarded[r["time"]].append(r)

    first, last = min(r["time"] for r in rows), max(r["time"] for r in rows)
    window = {t: v for t, v in oem.items() if first <= t <= last}

    print(f"logs: {len(rows)} glucose lines, {first} .. {last}")
    print(f"OEM:  {len(oem)} readings, {len(window)} in that window")
    print("decisions:", dict(decisions))
    print(f"resent live/cached records seen by the engine: {len(resends)}")
    print(f"other clients' history packets ignored: {ignored}")

    dup = {t: rs for t, rs in forwarded.items() if len(rs) > 1}
    print(f"\nforwarded more than once: {len(dup)}")
    for t, rs in sorted(dup.items())[:20]:
        print(f"  {t:%Y-%m-%d %H:%M} seq={rs[0]['seq']} x{len(rs)} values={[r['mgdl'] for r in rs]}")

    mmol_off, mgdl_off, compared = [], [], 0
    for t, v in sorted(window.items()):
        rs = forwarded.get(t)
        if not rs:
            continue
        r = rs[0]
        compared += 1
        if r["mmol"] != "?" and abs(float(r["mmol"]) - v) > 0.05:
            mmol_off.append((t, r, v))
        expected = round(v * FACTOR)
        if r["mgdl"] != "none" and abs(int(r["mgdl"]) - expected) > 0:
            mgdl_off.append((t, r, v, expected))
    print(f"\ncompared {compared} forwarded readings with the OEM export")
    print(f"  mmol/L different: {len(mmol_off)}")
    for t, r, v in mmol_off[:20]:
        print(f"    {t:%Y-%m-%d %H:%M} seq={r['seq']} trio={r['mmol']} oem={v}")
    print(f"  mg/dL != round(OEM x {FACTOR}): {len(mgdl_off)}")
    for t, r, v, e in mgdl_off[:20]:
        print(f"    {t:%Y-%m-%d %H:%M} seq={r['seq']} trio={r['mgdl']} expected={e} (oem {v})")

    missing = sorted(t for t in window if t not in forwarded)
    extra = sorted(t for t in forwarded if t not in oem)
    print(f"\nin OEM, not forwarded by Trio: {len(missing)}")
    for t in missing[:30]:
        why = [r["decision"] for r in rows if r["time"] == t]
        print(f"  {t:%Y-%m-%d %H:%M} oem={window[t]} trio={why or 'no glucose line'}")
    print(f"forwarded by Trio, not in OEM: {len(extra)}")
    for t in extra[:30]:
        print(f"  {t:%Y-%m-%d %H:%M} seq={forwarded[t][0]['seq']} mgdl={forwarded[t][0]['mgdl']}")

    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["time", "oem_mmol", "oem_mgdl", "seq", "trio_mmol", "trio_mgdl", "trend", "rate", "src", "decision"])
            for t in sorted(set(window) | {r["time"] for r in rows}):
                o = oem.get(t)
                rs = [r for r in rows if r["time"] == t] or [None]
                for r in rs:
                    w.writerow([
                        f"{t:%Y-%m-%d %H:%M}", o, round(o * FACTOR) if o else "",
                        *( [r["seq"], r["mmol"], r["mgdl"], r["trend"], r["rate"], r["src"], r["decision"]]
                           if r else [""] * 7),
                    ])
        print(f"\nwrote {args.csv}")


if __name__ == "__main__":
    main()
