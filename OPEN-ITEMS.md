# Open items

The work list between this kit and a GS3 driver someone can dose from. State as
of 2026-11-22, on the `rust-engine` branch.

Where things live:

* **Driver:** `cgm-sibionics` (Rust, `diagnostic-logging` branch), built into
  `Rust/CgmSibionicsFFI.xcframework` with `Scripts/build-rust.sh`. Its README
  lists the known limitations and deliberate deviations from the official app;
  its `.docs/to-confirm.md` lists what is unconfirmed (guideline S16).
* **Protocol research:** the private `sibionics-research` repository (full
  to-confirm detail, captures, the decompiled official app). Nothing about the
  protocol goes in this repository.
* **This kit:** the Trio adapter (LoopKit `CGMManager`, UI, alerts, logs).

---

## 29 Nov: end of life, then a new sensor

The current sensor started on 2026-11-15 at 02:08 local time, so its 14 days end
on **2026-11-29 at 02:08**. Do these in this order: the first observation is
lost if the sensor is ended early.

### The evening before (28 Nov)

1. Leave Trio Test running; do not force-quit it until the morning, so the log
   covers the end.
2. If you want the optional capture (step 7): install Apple's Bluetooth logging
   profile on the phone (it expires after a few days) and have PacketLogger on
   the Mac ready.
3. Have the new sensor and its applicator at hand.

### At the end of wear (02:08, no need to be awake)

4. Leave everything alone. In the morning, export the SibionicsKit logs for
   28 and 29 Nov and an official-app export, and check:
   * a line `sensor status: dstate 6 (expired)` around 02:08. This confirms the
     expiry code and the status mapping on hardware (to-confirm #10, #12);
   * no reading forwarded after 02:08: from then on every reading logs
     `not forwarded: Past wear` (the engine blocks at 14 days by its own clock,
     whatever the sensor does);
   * Trio shows **Sensor Expired** and raised the expiry alert;
   * what the sensor does after: records stop, placeholders only, or values
     keep coming (a grace period). Any of these is fine; it is the observation.
5. If `dstate` stays `1` past 02:08, that is a finding too: the sensor does not
   report its own expiry and the engine's clock is the only gate.

### Optional: the official app's stop (research only)

6. The engine never sends the stop command, so this does not block anything.
7. With PacketLogger capturing, use the official app's **Stop Using Current
   Sensor** on the expired sensor, if it still offers it. Save the capture in
   sibionics-research `captures/`. It shows the stop command's reply and the
   status after it (to-confirm #18).

### The new sensor (verifies activation on the Rust engine)

8. In Trio Test's Sibionics settings, tap **End Sensor** on the old one.
9. Apply the new sensor. Keep your existing account id in settings, so the
   official app can still read it. Do **not** let the official app start it.
   PacketLogger capturing is worth it here.
10. Pair through Trio Test's onboarding and scan the applicator. Check:
    * the log has exactly one `activating sensor at` line and pairing reports
      the sensor started;
    * for 60 minutes nothing is forwarded (`not forwarded: Warm-up`), and the
      home screen shows warm-up;
    * the first value arrives at about the 60-minute mark;
    * once the official app reads the sensor too, its values match.
11. If pairing ends with "may or may not have been started", pair again. Do not
    start another sensor: the engine reads the sensor's clock first and never
    starts one twice. Keep the log and the capture.
12. Afterwards, in settings: the **Previous Sensor** row is there, and its page
    shows the old sensor's ID, serial, start and paired dates, **Session
    ended**, and worn for about 14 days.

### Same day, small checks

13. Force-quit Trio Test only, wait 20+ minutes, reopen: no "No sensor
    readings" alert flashes in the first 2 minutes.
14. After that launch the log has `sensor status: dstate 1 (normal)` once.
15. Search one exported log for your account id: zero hits. (Logs from the old
    Swift driver, 19 and 20 Nov before 22:05, contain the encrypted auth frame
    and must not be shared.)

---

## Blocks a dosing release

1. **End of life on hardware** (steps 4–5).
2. **Activation by the Rust engine on hardware** (steps 8–12). The Swift driver
   has started a sensor, including with a generated account id; the Rust engine
   has only done it in the simulator.
3. **A few days of open loop** on the new sensor, comparing Trio's
   recommendations with the official app and your own judgement, before
   closing the loop.
4. **Release mechanics:** merge cgm-sibionics `diagnostic-logging` into `main`,
   write its CHANGELOG and tag it (guideline 12); point this kit at the tag
   instead of a local checkout and merge `rust-engine`; move Trio's SibionicsKit
   reference off the Swift driver (`c73dbda`).
5. **Licence:** cgm-sibionics is AGPL-3.0-or-later, this kit is MIT. Whether that
   can ship inside Trio on the App Store is open (cgm-sibionics README, Q8).

---

## On a spare phone (not blocking)

The main phone also runs the dosing Trio, so these wait for a second phone:
Bluetooth off for 25 minutes, out of range for 20+ minutes, a reboot, End
Sensor and pair the same one again, and a start with a *generated* account id
(on a spare sensor). They are about availability: reconnect and backfill are
already proven through a 9½-hour force-quit and the account-id tests.

---

## Done (20–22 Nov, Rust engine)

* **Values:** identical to the official app's export on every reading, in
  mmol/L. In mg/dL up to 1 higher on about 58 % of readings (the official app
  rounds down); a known limitation, kept on purpose.
* **Switch-over** from the Swift driver: no gap, no duplicate.
* **Backfill:** starts from the last reading before a gap. A 9½-hour quit came
  back complete (112 readings, one batch, no duplicates).
* **Arrows** are the sensor's own trend code and match the official app.
* **Account id:** a refused id stops reconnecting, shows a red **Comm. Error**
  with the reason in settings, survives a restart, and recovers with the right
  id without losing readings.
* **Alerts:** signal loss fires at 20 minutes and clears on the next reading; no
  flash at launch (2-minute grace).
* **Sensor health:** the sensor's own status (`dstate`) is read from every
  record. Failed needs three records in a row; expired, temporary issue and
  unusable hold readings back per record. Signal loss counts from the last
  *value*, so a sensor streaming without values does not look active. The
  zero-current check only flags readings; it never ends a sensor.
* **Previous sensor** is kept and shown, with shared identity rows.

---

## Open, not blocking

* **A temporary-issue status** of its own (guideline Q18). Today the readings
  are held back and the home screen falls back to signal loss.
* **Status codes 3–7** have never been seen on hardware; the meanings are the
  official app's.
* **Battery and crashes** over normal use: glance at Settings → Battery and the
  analytics crash list now and then.
* **The stop command's reply** (to-confirm #18), only from a capture.

---

## Out of scope

* **GS1 / GS1 Pro.** The glucose value is computed by an algorithm on the
  phone, which neither this kit nor the engine implements.
* **V2 firmware.** Detected and refused.
* **Calibration.** The GS3 V3 protocol has none.
* **Stopping a sensor.** Known, never sent: it is irreversible and a GS3 ends
  by itself after 14 days.

---

## On accuracy

The driver computes no glucose. The value is the sensor's own, passed through
unchanged, so any accuracy figure is the sensor's. What this code can get wrong
is decoding, timing and which readings it forwards, and the comparisons with the
official app's export are what check that.
