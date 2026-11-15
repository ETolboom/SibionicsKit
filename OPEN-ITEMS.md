# Open items

What is still between this kit and a GS3 driver anybody should trust. The
protocol itself is documented in [`README.md`](README.md) and
`/Users/erik/BuildTrio/GS3/GS3-protocol-notes.md`; this file is the work list.

Ordered by how much each one blocks the word "working".

---

## Blocks the claim

### 1. Activation of a real factory sensor

Every attach in the logs so far reads *"attaching to an already-activated
sensor"*. The `0x35` frame, the account binding and the ack are pinned to a
capture of the **official app** doing it, never to this driver doing it.

The whole activation branch is therefore proven by trace, not by use:
`SibionicsPairingService.activationDecision` decides, `activateBindIn` writes,
and the ack is checked by re-reading the clock — none of which has run against
hardware in anger.

**How to close it.** Start a fresh sensor with Trio, leave it for at least a few
hours, and confirm: the write is accepted (status `0x01`), the ack echoes our
timestamp, the first record index is ~0, and readings land. There is no way to
test this without consuming a sensor, which is exactly why it is still open.

**Watch for:** whether a factory sensor accepts a *generated* account id at all.
The capture only proves the id is compared, not that a blank sensor accepts an
unfamiliar one.

### 2. Alerts — first pass in, needs a real failure to confirm

`SibionicsAlert` + `SibionicsAlertEvaluator` + `CGMManager+Alerts` now raise three
things through LoopKit's pipeline, reconciled against what is already up:

| Alert | Trigger | Level |
|---|---|---|
| Signal loss | no record for 20 minutes | timeSensitive |
| Sensor failed | `state.sensorFault` (currently only `signalImplausible`) | critical |
| Sensor expired | `activatedAt + 14 d` | timeSensitive |

Signal loss is suppressed once the sensor is known gone (fault or expired) so one
event is not two alerts. A ticker drives it every 60 s, because signal loss is
defined by the *absence* of an event; everything else is evaluated on state
changes. `SibionicsAlertEvaluatorTests` covers the decisions, including the cases
that must stay quiet.

Still open:

* **Confirmed delivery.** Loop routes alerts through `AlertManager`, Trio through
  `TrioAlertManager`; older Trio builds dropped plugin alerts silently. Nothing
  here proves the user saw anything, and nothing has actually fired yet — every
  trigger needs a real failure (or two weeks) to exercise.
* **Sensor error from `dstate`/`tstate`.** Left out deliberately: the normal
  values are known (`dstate=1`, `tstate=0` in 394/394 records), but not what a
  deviation means, so triggering on it would be guesswork.
* **Expiry warning.** No advance notice (24 h, 2 h) before the 14 days run out.
  Worth adding once expiry itself is understood.

### 3. ~~Decode cross-check~~ — done

Closed against the official app's own export for one sensor: **173 of 173
readings matched exactly, no disagreements**, over the sixteen hours the two were
both running (indices 60–920 of 60–1015). Since neither side computes glucose,
exact agreement is the only correct result.

Pinned by `SibionicsOfficialGlucoseTests`, which replays all 192 exported
readings through `SibionicsRecord` from `Fixtures/official_glucose.bin`
(regenerate with `Scripts/make_official_fixture.py`). Also pinned there: the
export starts at index 60 and steps 5 minutes, i.e. warmup is 60 minutes and the
sensor produces one value per five one-minute indices.

---

## Resolves by observation

No work planned; these close themselves by leaving the sensor attached.

* **A full 14-day wear**, and what the sensor does at the end of it — whether it
  announces expiry, goes quiet, or starts failing records. We currently assume
  the last of these.
* **Multi-packet history backfill on hardware.** The `last = 0` fix is newer than
  the last hardware session, so a real paged batch has not been observed yet.
* **Reconnect durability** across days, sleep, backgrounding and reboots.
* **Warmup (60 min)** as an actual observed transition rather than a constant.
* **Trend agreement** — the driver derives its own trend from consecutive
  readings instead of trusting the vendor's 3-bit field. They should agree; if
  they do not, the 3-bit mapping is the wrong one to keep.
* **Whether anything ever fires.** The alerts only prove themselves on a real
  signal loss, failure or expiry.

---

## Protocol unknowns

Each of these is decoded but unverified, or observed but not understood.

* **`tstate` / `dstate`.** Observed as `tstate=0` and `dstate=1` in 394 of 394
  records — a clean baseline, but no record of what a deviation looks like. This
  is the most promising source of a real "sensor error" signal, and the reason it
  is on this list rather than in the alerts table as a certainty.
* **The `01 00` reply** to a history request. Discovered by accident (it is what
  a bounded `last` produces). Now handled as a batch terminator, but nothing
  establishes whether it means "invalid range", "no data" or something else.
* **`0x36` cached-record path.** Coded, never observed in a log.
* **The `0x39` `tail` field.** Parsed, kept raw, meaning unknown.
* **Plausibility thresholds** in `SibionicsPlausibilityGuard`. Chosen here, not
  measured; they decide when a sensor gets latched as failed.
* **`present_cstate` asymmetry.** Vendor-set on the record and used to drop it,
  but no sample has ever carried it.

---

## Out of scope

Not "untested" — deliberately not implemented, for the reasons in the README.

* **GS1 / GS1 Pro.** A different product: the glucose value is computed by a
  native algorithm *on the phone*, which this kit does not implement. Supporting
  it means porting an algorithm, not a decoder.
* **V2 firmware.** Different transport (RC4) and a separate `0x0F` activation.
  Detected and refused.
* **Re-binding, deactivation, OTA.** No V3 command is known for any of them, and
  a GS3 cannot be moved to a different account once activated.

---

## On accuracy

Worth being precise, because "working" and "accurate" are different claims.

The driver computes no glucose. The number is the sensor's own
(`mmolLx10 * .1 * convfactordL`), so there is no local algorithm to diverge from
the vendor's and no possibility of a discrepancy being introduced here. Any
accuracy figure this kit produces *is* the sensor's accuracy.

That also means a MARD study against YSI or a meter would be measuring Sibionics'
algorithm, not this code — which does not make it worthless, only somebody else's
result to publish.

The one thing that *can* go wrong here is item 3 above: a decode error that
scales or offsets everything. That is a correctness bug, not an accuracy one, and
the official-app comparison is what catches it.
