#!/usr/bin/env python3
# Copyright (c) 2026 Nightscout Foundation.
# Licensed under the MIT License. See LICENSE in the project root.
"""Turn the official app's glucose export into a replayable test fixture.

Input is the `.xlsx` the Sibionics app itself writes (Share / Export → "Sensor
Glucose"), two columns: `Time` and `Sensor Reading(mmol/L)`.

Output is the dense binary the tests read, in the same spirit as SyaiKit's
ground-truth dumps: only the fields a test needs, and no absolute timestamps, so
no personal trace lives in the repository.

    magic   4 B  "SGS3"
    version 1 B  = 1
    count   4 B  little-endian UInt32
    records      count × (index: UInt16, mmolX10: UInt16), little-endian

`index` is the sensor's own minute index since activation, recovered from the
export's timestamps by subtracting the activation time reported by `F0 03`.
`mmolX10` is the displayed value ×10, i.e. the raw value of the record's
display-glucose field, which is why it is an integer.

Usage:

    python3 Scripts/make_official_fixture.py \
        ~/Downloads/SibionicsGS3_AAC26910943L.xlsx \
        SibionicsKitTests/Fixtures/official_glucose.bin \
        --activated-at 2026-11-15T01:08:11Z
"""

import argparse
import datetime as dt
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def read_rows(path):
    tmp = tempfile.mkdtemp()
    try:
        subprocess.run(["unzip", "-o", "-q", path, "-d", tmp], check=True)
        shared = []
        shared_path = os.path.join(tmp, "xl/sharedStrings.xml")
        if os.path.exists(shared_path):
            for si in ET.parse(shared_path).getroot().findall(NS + "si"):
                shared.append("".join(t.text or "" for t in si.iter(NS + "t")))
        sheet = ET.parse(os.path.join(tmp, "xl/worksheets/sheet1.xml"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    rows = []
    for row in sheet.getroot().iter(NS + "row"):
        cells = {}
        for cell in row.findall(NS + "c"):
            column = re.sub(r"\d", "", cell.get("r"))
            value = cell.find(NS + "v")
            text = value.text if value is not None else None
            if cell.get("t") == "s" and text is not None:
                text = shared[int(text)]
            cells[column] = text
        rows.append(cells)
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("xlsx")
    parser.add_argument("out")
    parser.add_argument(
        "--activated-at",
        required=True,
        help="activation time from F0 03, ISO 8601 with offset, e.g. 2026-11-15T01:08:11Z",
    )
    args = parser.parse_args()

    activated = dt.datetime.fromisoformat(args.activated_at.replace("Z", "+00:00"))
    rows = [r for r in read_rows(args.xlsx) if r.get("A") and r.get("B")]
    header, data = rows[0], rows[1:]
    if "Time" not in (header.get("A") or ""):
        sys.exit(f"unexpected first row: {header}")

    records = []
    for row in data:
        stamp, value = row["A"], row["B"]
        # "14-11-2026 19:08 GMT-7"
        day, clock, zone = stamp.split(" ")
        d, m, y = (int(p) for p in day.split("-"))
        hh, mm = (int(p) for p in clock.split(":"))
        sign = -1 if zone[3] == "-" else 1
        offset = dt.timezone(sign * dt.timedelta(hours=int(zone[4:])))
        when = dt.datetime(y, m, d, hh, mm, tzinfo=offset)

        # The export truncates to the minute, so the index is rounded rather
        # than floored: activation + n minutes lands a few seconds off :00.
        index = round((when - activated).total_seconds() / 60)
        records.append((index, round(float(value) * 10)))

    if not records:
        sys.exit("no data rows")
    indices = [i for i, _ in records]
    if any(b - a != 5 for a, b in zip(indices, indices[1:])):
        sys.exit(f"expected a 5-minute grid, got gaps {sorted({b - a for a, b in zip(indices, indices[1:])})}")

    with open(args.out, "wb") as f:
        f.write(b"SGS3")
        f.write(bytes([1]))
        f.write(len(records).to_bytes(4, "little"))
        for index, mmol in records:
            f.write(index.to_bytes(2, "little"))
            f.write(mmol.to_bytes(2, "little"))

    print(
        f"{len(records)} records, index {indices[0]}…{indices[-1]}, "
        f"first {records[0][1] / 10} mmol/L, wrote {args.out}"
    )


if __name__ == "__main__":
    main()
