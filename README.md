# SibionicsKit

Trio / Loop CGM driver for **Sibionics GS3** sensors, V3 firmware.

> ### Status: draft, not usable for dosing
>
> This is a scaffold built from static analysis of the official app plus a
> protocol write-up. It has **never run against a real sensor**. The frame
> layout, cipher and command opcodes are validated against independent
> references (see [What is actually verified](#what-is-actually-verified)), but
> the record semantics, ack status bytes and the BLE advertisement are not.
> Do not let this drive insulin until someone has confirmed it on hardware.

## On the `rust-engine` branch: the Rust driver

On this branch the protocol runs in Rust: [`cgm-sibionics`](https://github.com/open-source-aid/cgm-sibionics)
(sans-IO, written to the OS-AID driver guideline, on the
[`cgm-shared`](https://github.com/open-source-aid/cgm-shared) contract). The Swift session,
pairing service, monitor, trend tracker, plausibility guard, codec and cipher are gone;
`main` keeps them.

| Piece | Where |
|---|---|
| Protocol, pairing/activation, history, trend, plausibility, warm-up/wear, signal loss | Rust engine (`cgm-sibionics`) |
| Bindings (UniFFI) | `cgm-sibionics/ffi`, generated into `SibionicsKit/Rust/Generated/` |
| Host runtime: CoreBluetooth, Keychain, SecRandom, timers | `SibionicsKit/Host/SibionicsRustHost.swift` |
| LoopKit adapter: 5-minute grid, sync id, samples, alerts, reconnect backoff | `SibionicsKit/Services/CGMManager+*.swift` |

Build the Rust library before building the kit:

```sh
Scripts/build-rust.sh            # expects "../../../Unified OS-AID/cgm-sibionics", or pass its path
swift test                       # bindings + remaining Swift tests
```

The XCFramework (`Rust/CgmSibionicsFFI.xcframework`) is not committed. An existing
pairing carries over: the first reconnect pairs the engine again from the stored
peripheral, account id and start time, which never re-starts a sensor. Sync identifiers
are unchanged (`sibionics-<mac>-<seq>`), so Trio deduplicates across the switch.

The `sibionics-decode` capture decoder now lives with the driver: `cgm-sibionics/decode`
(`cargo run -p cgm-sibionics-decode --bin sibionics-decode -- --mac … capture.pklg`).

What is still open, and the plan for the sensor's end of life and the first activation
by the Rust engine, is in [`OPEN-ITEMS.md`](OPEN-ITEMS.md).

## Why it exists

Sibionics GS3 sensors are read through the vendor app, which requires a cloud
login and keeps the sensor to itself. The protocol turned out to be simple enough
to speak directly: one GATT service, one request/response characteristic, and an
application-layer cipher with no bonding and no key exchange.

The GS3 is unusual in one respect that matters here: **the sensor computes its own
glucose**. The record carries the value the vendor app displays, so the driver
forwards that rather than running an algorithm. That removes a whole class of
"is my decode right" risk, and it means an already-activated sensor can be read
with nothing but its MAC and the account id that activated it.

## Scope

| | |
|---|---|
| Supported | **GS3**, protocol generation **V3** (`_V3.` in the Device Information software revision) |
| Not supported | **V2** firmware (different transport and auth; recognised and refused) |
| Not supported | **GS1 / GS1 Pro** (a different product that shares some opcodes) |
| Not implemented | Re-binding a sensor to a different account, deactivation, OTA |

### GS3 vs GS1, and the V2/V3 firmware split

Three different things get called "the protocol", and only the first is a
product difference:

* **GS3 vs GS1** — a *product* difference, and the important one. A GS3 computes
  glucose **on the sensor**: the record carries a finished value plus the raw
  currents and voltages, and this driver decodes and forwards it. GS1 is the
  older product, and Juggluco's path for it (`main/cpp/sibionics/`) hands raw
  data to a native algorithm on the *phone*. So GS1 is not "GS3 with a different
  cipher" — the glucose value does not exist until that algorithm runs. This kit
  does not implement it, which is why GS1 is out of scope rather than untested.
* **V2 vs V3** — a *firmware* difference within the GS3 line, not a product one.
  V2 is RC4 and activates through a separate `0x0F` command; V3 is AES-128-OFB,
  where the `0x35` activation frame *is* the binding. Detection is deliberately
  blunt and fails closed: anything whose software revision does not contain
  `_V3.` is treated as V2 and refused with the generation in the message, so an
  unrecognised firmware string shows up as a refusal rather than as
  undecryptable nonsense.
* **Region** — not a protocol difference at all. `SISENSING-GNL` (global) and
  `SISENSING-CN` (China) are the same transport.

### Verified against

Everything below was established against one sensor. The strings are worth having
written down, because a firmware revision is the first thing to suspect when a
sensor stops behaving:

| Characteristic | Value |
|---|---|
| `2A24` model | `GS3*-5EANLA` |
| `2A28` software revision | `1.1.6I_V3.4.0` — firmware `1.1.6I`, protocol `V3.4.0` |
| `2A29` manufacturer | `SISENSING-GNL` (global) |
| `2A25` serial | the MAC, and the source of the cipher's IV |

## Requirements

* A Sibionics GS3 sensor. Nothing else.

The transport cipher's IV is derived from the sensor's MAC, and the MAC is the
sensor's own `0x2A25` serial number characteristic — read over GATT after
connecting, so pairing needs no NFC scan, no printed code and nothing typed.
(Verified against a hardware capture; the app's own ordering tricks do not
introduce a reversal.)

### The account id, and why there is nothing to fetch

The one per-user value in V3 is a 12-byte *account id* inside the auth frame.
Everything else — transport key, registration key, algorithm-glucose mask — is a
static constant of the protocol, and the IV is derived from the MAC.

Where the account id comes from depends on who activated the sensor:

* **A fresh sensor.** V3 has no separate bind step, so the account id in the
  activation frame (`0x35`) *is* the binding — a sensor in factory state takes
  whatever it is first given. This kit therefore **generates one on the device**
  (a full-range random 64-bit value, stored in the Keychain) and never asks
  anyone for it. You cannot "log in wrong": there is nothing to log into.
* **A sensor the official app already activated.** That sensor only answers the
  account id it was activated with, so the driver needs that single value. It is
  the only thing that would ever have to be obtained from the vendor's service,
  and only for that case — enter it in Settings.

Because the account id is generated, it is also doing the work of a key: anyone
who knows a sensor's MAC and its account id can read it. It is stored in the
Keychain (never in the plist state) and must survive a reinstall, since a sensor
is unreadable without it.

The driver checks this before spending anything: it authenticates and reads the
sensor clock *before* writing an activation command, so a rejected id costs a
connection, not a sensor. A refusal is surfaced as `accountRejected` (see
`SibionicsSession.SessionError.authenticationRejected`) and never as a retry.

## Moving an existing sensor over

If the official app activated the sensor, Trio can read it — the sensor compares
one value and nothing else, and that value is the account id. So:

1. **Settings → Account ID** and enter the id the official app used (its user
   profile id, in Settings → Preferences).
2. Pair it. The MAC comes from the sensor's own serial number, so there is
   nothing to scan.

There is nothing to switch on or off for this: a sensor that is already running
reports its activation time, so pairing it only ever authenticates.

Changing the account id (or the registration key, under Debug) reconnects and
re-authenticates. **Nothing is ever written to a sensor on that path** — a wrong
id fails the auth probe and stops there.

Two things to know about a moved sensor:

* Its start time may be unavailable. The official app learns it from
  Sibionics' servers; `0xF0 0x03` would give it, but the app never asks, so a
  firmware may not answer. When it does not, the driver attaches read-only and
  derives the start time from the first record's index — about a minute of
  accuracy, corrected as soon as anything better appears, and persisted.
* Close the official app first. A sensor talks to one phone at a time.

If the account id is right and auth is still refused, the next suspect is the
per-app registration key (Debug → Registration key, `gs3` is the verified one).

## Activation

Reading an already-activated sensor is safe. **Activating** one is not: the
sensor is single-use, the command writes the clock origin that every later
reading is dated from, and there is no V3 command to correct it afterwards.

There is no toggle. The sensor decides, and it is the only thing that can: pairing
queries the clock (`F0 03`), and **a sensor is activated only when that query
answered and reported `activation_time == 0`.** A clock reply that never arrived
is not evidence of anything, so it attaches read-only and learns the start time
from the first record — activating on that guess would stamp a running sensor with
a new start time and a new account id. Already-activated sensors take the same
read-only path, which is what makes moving one from the official app work.

The policy lives in one testable place, `SibionicsPairingService.activationDecision`,
and is confirmed by effect rather than by ack: after writing `0x35`, the driver
requires a non-zero activation stamp. If the sensor will not confirm, the pairing
fails loudly instead of pretending it worked.

## Reading a capture

`sibionics-decode` uses the *same* cipher and record parser as the driver, so a
trace is interpreted exactly the way the driver would interpret it — if the
driver's reading of the protocol is wrong, the decoder is wrong in the same way,
which is a more useful signal than a second implementation would be.

```sh
swift run sibionics-decode --mac AA:BB:CC:DD:EE:FF capture.btsnoop
swift run sibionics-decode --mac AA:BB:CC:DD:EE:FF capture.pklg
swift run sibionics-decode --mac AA:BB:CC:DD:EE:FF < capture.txt   # hex lines
```

It reads Apple's PacketLogger `.pklg` and Android's `btsnoop` directly — no
`tshark` needed — or a text file of hex, one value per line, optionally prefixed
`phone`/`sensor` or `tx`/`rx`.
Everything non-hex is ignored, so a `tshark` dump drops in unmodified. Frames are
identified by decryption rather than by handle, so `ff31`/`ff32` do not have to be
separated first, and other characteristics' traffic is simply reported as "not
our traffic".

The auth frame prints the registration key and account id it carried:

```
AUTH
  mac on the wire (already reversed): AA:BB:CC:DD:EE:FF
  registration key text: "THE544U0TYITE461"
  account id (12 B):     00000000000004d200000000
  known key match:       gs3 / sijoy (verified upstream)
```

A wrong MAC decodes to nothing rather than garbage: nothing else passes the
checksum.

## Pairing from the applicator tag

The tag does **not** carry the MAC — a real GS3 tag reads

```
GJ,04ES126090500NA,6,10943L
```

which is an app prefix, the **product serial**, a one-digit code and a lot
number. (That is not the shape the original notes guessed at, which had a region
and a MAC.) The serial is the same string the sensor reports from `F0 0E`, and
that is what makes tag-based pairing worth doing:

1. **Scan sensor tag and connect** reads the tag and takes its serial.
2. It scans for the sensor and connects — the MAC still comes from the sensor's
   own `0x2A25`, so nothing has to be typed either way.
3. After authenticating it reads `F0 0E` and **checks the serial matches the
   tag**. A mismatch is refused with "that is a different sensor", so the tag is
   genuinely verifying which physical sensor you attached to, not just decorating
   the flow.

The registration key is *not* needed from the tag either — it is a per-app
constant.

## Reading the applicator tag

Settings → **Diagnostics → Read NFC tag and dump it** (and, during onboarding,
**Scan the sensor's tag**, which fills the MAC in for pairing).

It prints the tag type, UID, NDEF status and every raw payload, then what the
driver parses out of it:

```
Sibionics NFC debug dump
tag:      MIFARE Ultralight (ISO14443)
uid:      04a1b2c3d4e5f6
NDEF:     read/write, capacity 137 B
payloads: 1

[0] well-known/T "GJ,GS3*-BEABMA,GNL,AAC25B18AAFZ,E2AFF9F01F19,PG291,HT"
    raw: 02 65 6e 47 4a 2c 47 53 33 ...

parsed record:
  fields: GJ | GS3*-BEABMA | GNL | AAC25B18AAFZ | E2AFF9F01F19 | PG291 | HT
  mac:    E2:AF:F9:F0:1F:19
  ble name suffix: BEABMA
```

`Copy` puts the whole thing on the clipboard, which is the point: the field
layout is a **guess** (the parser takes the first 12-hex-digit field as the MAC),
and a raw dump is the only way to check the guess against a real applicator. If
the parse is wrong the dump still shows the truth.

Notes:

* The official app uses `NFCNDEFReaderSession`, so the tag is plain NDEF — the
  payload is readable by any NFC app and is not a secret. Only the field layout
  was unknown.
* This uses `NFCTagReaderSession`, because Trio's entitlements already carry
  `com.apple.developer.nfc.readersession.formats = [TAG]` for Libre. That needs
  no build-config change. An applicator tag that only presents as ISO-DEP
  (NFC Forum Type 4) would need the `NDEF` entitlement and an NDEF session
  instead; the failure is reported as `connectFailed`, not silently.
* Tag reads are local only. Nothing is sent anywhere.

## Getting a capture

| Route | Cost | Notes |
|---|---|---|
| **Android HCI snoop** | free, needs root to pull | Easiest. Developer options → *Enable Bluetooth HCI snoop log*, toggle Bluetooth, do the pairing, pull `/data/misc/bluetooth/logs/btsnoop_hci.log`. |
| **Passive BLE sniffer** | ~$10 nRF52840 dongle | Works with *any* phone, including a locked iPhone. Feasible only because GS3 has **no BLE bonding or link-layer encryption**, so the app-layer ciphertext is all there is — and it is the same vulnerability the driver relies on. nRF Sniffer for Wireshark follows the connection itself. |
| **iOS + PacketLogger** | free-ish, fiddliest | iOS has **no** equivalent of the Android snoop log. What works is Apple's Bluetooth logging profile (developer portal) plus *PacketLogger* from *Additional Tools for Xcode*. It writes `.pklg`, which this kit now parses. **This has been done end to end** — the layout and the resulting decoded conversation are in `/Users/erik/BuildTrio/GS3/GS3-protocol-notes.md`. |

Because the protocol is unencrypted at the link layer, any of the three captures
the identical bytes. The iPhone route is only more work, not more capable.

## What about a network capture?

Not needed for the driver, and hard on iOS, which is why it isn't in the list
above.

The protocol cannot depend on the server for the part that matters. The
activation frame is 19 bytes: a `u32` timestamp and the 12-byte account id.
There is no room in it for a token, and the sensor has no channel to the vendor,
so it cannot require that the server sanctioned the write. The auth frame's two
"interesting" fields — the 16-byte registration key and the 12-byte account id —
are both plaintext in the BLE capture.

One thing worth knowing, because it looks alarming until it isn't: the
registration key *is* seeded from the network. The iOS app's
`SibAccessTokenManager` requests a `SibAuthModel` using `SibBleSDKOption`'s
appId/secret and derives the 16 bytes from the returned `appKey` with a static
RC4 key. So the registration key is server-*issued* — but it is a function of
the app identity, not of the account, which is exactly why the same short string
works for every user of a given build. It also means the value can in principle
rotate with an app release, and the only way to know is to look at a capture.

Cost side: this app pins (`GJAFSecurityPolicy` with `pinnedPublicKeys`, plus a
`URLSession` auth-challenge handler), so a plain proxy just gets a TLS error.
Reading the traffic means a jailbreak and unpinning, to learn something the BLE
plaintext already states.

## V3 reference trace checklist

Capture, in this order, and most of the open questions answer themselves:

1. **Official app activating a fresh sensor.** Decrypts to the exact activation
   sequence, the auth ack's status byte, the reply framing (length-prefixed or
   command-first), whether anything is written before `0x35`, the registration
   key, and the account id. Zero risk, answers the most.
2. **Ten minutes of streaming.** Confirms `0x32` cadence, whether `0x36` arrives
   on connect, temperature/current scales, and the `presence_cstate` meaning.
3. **A history read** (open the app's log/graph view). Confirms records per
   packet, whether the second `u16` is `0` or `0xFFFF`, and how the batch ends.
4. **The advertisement** (`nRF Connect`, no rooting needed). If it carries the
   MAC, pairing becomes scan-and-pick instead of typing a MAC.
5. **Only then**, our driver against a sacrificial sensor.

## Architecture

Same shape as the sibling kits, so it is easy to hold in your head next to them:

```
SibionicsKit/
  Crypto/      AES-128-OFB (CommonCrypto), AES-ECB block primitive, MAC→IV
  Protocol/    frame codec, opcodes, record decode, account-id encoding
  BLE/         GATT map, CoreBluetooth central/peripheral, session
  Sensor/      monitor (record → dated reading), lifecycle, plausibility guard, store
  Pairing/     NFC record parsing, connect/auth/activate orchestration
  Services/    CGMManager + state + ingest/reconnect/settings
  Models/      GlucoseSample, DeviceInfo
SibionicsKitUI/     onboarding + settings
SibionicsKitPlugin/ the LoopKit plugin entry point
SibionicsKitTests/  58 tests, no hardware required
```

The seams that matter:

* **`SibionicsGATTTransport`** — the only BLE surface the protocol sees, so the
  whole session can be tested against a fake sensor (which is what
  `SibionicsSessionTests` does).
* **`SibionicsSession`** — owns request/response, decryption and the
  reply-vs-record demultiplexing. Nothing above it knows about frames.
* **`SibionicsSensorMonitor`** — the only place that maps a record index onto a
  wall-clock date, using the sensor's own activation stamp.
* **`CGMManager+Ingest`** — the only place that decides what reaches Loop.

Everything downstream of the monitor is expressed in **record indices**, not
wall-clock time. The index ticks once a minute from activation and is what the
forwarding grid, the dedup key and the backfill watermark all use, so a phone
clock hiccup cannot interleave or duplicate readings.

## The protocol, briefly

```
frame   [len] [cmd] [payload …] [checksum]      len = size-1, sum(all) == 0 mod 256
cipher  AES-128-OFB, static key, IV = reverse(mac) ‖ 0×10, restarted per frame
auth    25 E2 00 | mac(6) | registration key(16) | account id(12) | cksum   (38 B)
start   12 35 | unix seconds u32 LE | account id(12) | cksum               (19 B)
info    03 F0 <sub> <0x0D - sub>                                           (4 B)
history 06 39 <first u16> <last u16> <cksum>                               (7 B)
record  16 B LE: temperature, dump, current, display glucose (mmol/L×10),
        algorithm glucose (masked), trend/state, state, CE, RE
```

Full details, including how the opcodes were recovered and which parts are
guesses, are in `/Users/erik/BuildTrio/GS3/GS3-protocol-notes.md` and `GS3-activation-findings.md`.

## What is actually verified

**Against a real capture.** `SibionicsCapturedTraceTests` decrypts every frame
of an official-app activation (`GS3 Activation.pklg`) and asserts the plaintext,
so the cipher, the framing and the field layouts are pinned to what the sensor
actually does. What that settled:

* **The IV is the sensor's `0x2A25` serial number verbatim**, then zeros — *not*
  reversed. (The earlier notes said reversed; the first draft of this driver
  inherited that and could not decrypt anything.)
* **Replies are length-prefixed** `[len][cmd][payload][cksum]`. The auth ack is
  `04 E2 01 00 19`, five bytes, not the three-byte `E2 01 00` the notes
  recorded. Status byte `0x01` is success.
* **The registration key is `THE544U0TYITE461`** — the constant already in the
  code, now observed on the wire instead of inferred.
* **The account id** was 8 bytes big-endian + 4 zeros, matching the numeric
  encoding path.
* **The activation frame** `12 35 <time LE> <account> <cksum>` is exactly what
  the app writes, and the ack echoes the timestamp — which is what this driver
  now uses to confirm an activation, instead of a device-clock read the app
  never performs.
* **An empty history reply is two payload bytes** (`04 39 00 05 BE`), so a
  zero-count packet must be accepted as the terminator, not rejected as short.
  A two-byte payload is not a truncated packet: it is the five-byte ACK form
  `[04][cmd][status][detail][cksum]`, which Juggluco's `handle_ack` reads as
  `status 0` = success (nothing to send) versus anything else = refusal.
  `04 39 00 05` is the success case, `04 39 01 00` a refusal. Both end the
  batch — a batch that cannot terminate wedges the consumer — but only one of
  them means we asked for something the sensor could answer.
* **A history request must ask for "to the end"** — `39 <first> 00 00`. The
  official app hard-codes `0` in the second slot (`06 39 01 00 00 00 c0`), and
  Juggluco's `0xFFFF` is not interchangeable.
* **The driver's numbers match the official app exactly.** Its own export for one
  sensor was replayed through the decoder: 173 of 173 overlapping readings equal,
  and the 192-row export starts at index 60 and steps 5 minutes. Since neither
  side computes glucose, exact agreement is the only correct result on this path.
  Pinned by `SibionicsOfficialGlucoseTests`.
* **A frame can be at most 256 bytes** — `len` is a single byte — so a history
  packet holds at most 15 records and a long gap always needs several round
  trips. Backfill re-requests until the range is covered; it used to stop at the
  first batch end, which is why it looked like it only went back about an hour.

### Against the official app's own export

The strongest evidence so far, because it needs no protocol interpretation at
all: the official app was asked to export its own readings for one sensor
(`SibionicsGS3_AAC26910943L.xlsx`, sheet *Sensor Glucose*, two columns), and the
driver's log was compared with it reading by reading.

| | |
|---|---|
| Export covers | 192 readings, 16 hours, 5-minute grid |
| Sensor indices | 60 … 1015 |
| Overlap with the driver's log | 173 readings |
| **Agreements** | **173 of 173, none different** |

Three things follow from that, beyond "the numbers match":

* **Warmup is 60 minutes.** The export's first row is index 60, not 0 — the
  sensor starts indexing at activation but produces nothing worth exporting
  until the hour is up. That turns a configurable guess into an observation.
* **The sensor produces one value per five one-minute records.** The missing
  minutes are not lost: they arrive as `0xFF01`
  (`SibionicsRecord.glucoseNoResult`), which is why a nine-hour log holds 1,378
  of them.
* **A decode error is what this rules out.** The driver computes nothing of its
  own, so the only way it could disagree is a wrong offset, byte order or scale
  factor — and any of those would shift *every* value, in the same direction,
  for all 173 points. None did.

Reproduce it with `Scripts/make_official_fixture.py` (xlsx → dense binary
fixture) and `SibionicsOfficialGlucoseTests`, which replays all 192 exported
readings through the real decoder.

### What one nine-hour session shows

Mined from the log of a single overnight run (2026-11-15, 00:11–09:29 local),
which is the only long session captured so far:

* **The link was being killed by us every six minutes** — 92 connections over
  nine hours, 86 of them ending `orderly`, median gap 364 s. That looked like the
  sensor hanging up; it was the stale-link watchdog, armed once per connection and
  never reset by incoming records, so it closed a perfectly healthy link exactly
  360 s after it opened and the driver reconnected. Re-arming it on every record
  removed both the churn and the duplicate re-reads each reconnect caused.
* **394 realtime records** over indices 370 → 920, plus 1,378 `0xFF01` no-result
  records — the four minutes in every five that carry no value, exactly as the
  export implies.
* **No faults.** Nothing tripped `SibionicsPlausibilityGuard`, `present_cstate`
  never appeared, and the `0x36` cached-record path never occurs in this capture.
* **History requests failed 169 times**, and 132 of those were the same bug: a
  *bounded* `last` answered with a two-byte `01 00` (see above). That one is
  root-caused and fixed. The remaining 32 were an unnamed `SessionError`, which
  is what the new `LocalizedError` conformance exists to identify next time.



What is left to do — activation on real hardware, alerts, and the protocol
unknowns — is tracked in [`OPEN-ITEMS.md`](OPEN-ITEMS.md). Still unverified, in
rough order of how much they block a claim of "working":

* **Activation of a real factory sensor.** Every attach so far has logged
  *"attaching to an already-activated sensor"*. The `0x35` write is pinned to a
  capture of the *official app* doing it, never to this driver doing it. Until a
  fresh sensor is activated and goes on to stream, the first half of the sensor
  lifecycle is proven only by trace.
* **32 history failures whose cause is still unknown.** The log has them as an
  unnamed `SessionError`; the `LocalizedError` conformance was added so the next
  capture says which. Until then, treat any non-`01 00` history failure as
  unexplained.
* **A full 14-day wear, and what the sensor does at the end of it** — whether it
  announces expiry, simply stops, or starts failing records.
* **History backfill on hardware.** The `last = 0` fix (see above) is newer than
  the last hardware session, so a real multi-packet batch has not been observed.
* **Alerts.** Signal loss, sensor failure and expiry are now raised through
  LoopKit's pipeline (`SibionicsAlertEvaluator`), but none has ever fired for
  real, and whether the host delivers a plugin alert is its own question.
* **Accuracy.** Nothing here is validated against blood glucose or YSI, and it
  cannot be: the driver computes nothing, so that would be the sensor's accuracy
  rather than this code's — see [`OPEN-ITEMS.md`](OPEN-ITEMS.md#on-accuracy) — and the
  decode itself is now cross-checked against the official export above.
* What is left on the decode side: the `0x36` cached-record path, the `0x39`
  paging `tail` field, and whether the vendor's 3-bit trend matches the
  driver's own derived from consecutive readings.
* Wear (14 d) and the plausibility thresholds in `SibionicsPlausibilityGuard` are
  judgement calls taken from the vendor's published figures or chosen here.

## Safety posture

* Activation is off by default and double-gated.
* A record flagged `present_cstate` is dropped, not forwarded.
* Warmup and past-wear readings update freshness but are never forwarded.
* A sensor that answers with its unauthenticated bootstrap frame is reported as
  such, never as "no data".
* A wrong MAC shows up as `undecryptable` rather than as a plausible reading.
* The plausibility guard suppresses forwarding on a dead electrode and latches
  the sensor as failed only after a longer streak; both are persisted.

## Building

The project is meant to be built inside the Trio workspace, alongside
`LoopKit`, exactly like the other kit projects: add it as a submodule, add the
`.xcodeproj` to the workspace, and embed `SibionicsKitPlugin.loopplugin` in the
app.

`project.pbxproj` is generated (Xcode 16 synchronized folders), so adding files
does not need a project edit:

```sh
python3 Scripts/gen_pbxproj.py SibionicsKit.xcodeproj/project.pbxproj
```

The protocol and BLE layers have no LoopKit dependency, so they can be exercised
without the workspace:

```sh
swift test        # 58 tests, no hardware
```

## Position and disclaimer

Independent, community-driven work. Not affiliated with, endorsed by or supported
by Sibionics. Use at your own risk, keep a working fallback therapy available,
and never dose on readings you have reason to doubt.

## License

MIT — see [LICENSE](LICENSE).
