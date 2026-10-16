# Zhiyun ZY Vega light BLE protocol (from libzylink.so arm64, app 1.1.7)

Confidence tags: **[V]** confirmed in the disassembly or Java, **[I]** inferred from strong evidence, **[G]** guess. Firmware has not been tested on hardware.

## 1. Transport
- GATT service `0000FEE9-0000-1000-8000-00805F9B34FB`.
  - Write char `D44BC439-ABFD-45A2-B575-925416129600`: **write without response** (Nordic `writeCharacteristic(..., 1).split()`). [V]
  - Notify char `...129601`. [V]
- The app requests MTU 517. Nordic `.split()` cuts a frame into raw chunks of (MTU-3) bytes, with **no fragment header**. [V] Frames for light control are 10–21 bytes, so a 23-byte MTU (20-byte payload) is enough for everything except long string replies.
- RX path: the native `ZYLightParser` is a byte-stream state machine. It resyncs on `0x24`, uses the length field, and validates the CRC, so notifications can be fragmented or concatenated arbitrarily. [V]
- **No encryption and no key** on FEE9. The bytes built by the C++ code go unmodified to `NewByteArray`/`SetByteArrayRegion` and are written raw to the characteristic. [V] The mesh-proxy characteristics (1828/2ADD/2ADE) are used only for Nordic mesh provisioning and configuration (AppKey add, etc.), not for ZY commands.
- The Java side refuses to drive a device that is not mesh-provisioned (`"不能直接使用非配网设备"`). That is an app policy. Whether the firmware ignores FEE9 writes before provisioning or registration is unknown. [G]

## 2. Frame format (all multi-byte fields little-endian) [V]
```
off size field
0   2    magic   24 3C            ('$','<'; ZYLightPacket ctor stores u16 0x3C24)
2   2    len     = payload_len + 6  (covers field3+seq+cmd+payload, NOT magic/len/crc)
4   2    field3  00 01             (u16 0x0100, constant on TX; RX reads whatever is sent)
6   2    seq     global counter, starts at 1, +1 per packet (static seq_no_ under a mutex)
8   2    cmd
10  n    payload
10+n 2   crc     CRC-16/XMODEM over bytes [4 .. 10+n)  (i.e. field3..end of payload)
```
CRC: `zy::crc` @0x14d5b4. It uses a 256-entry table at 0x99dae, which is byte-identical to the CRC-CCITT 0x1021 MSB-first table (checked programmatically). Init 0, no reflection, no xorout = CRC-16/XMODEM (check("123456789") = 0x31C3). It is stored with `WriteUInt16ToArray` (`strh`, LE). [V]
RX uses the same layout, and the parser recomputes the CRC the same way. [V]

## 3. Payload types
### 3a. "Functional" commands, 0x10xx (`zy::FunctionalPacket(cmd,id,rw,datalen)`) [V]
payload = `id:u16 LE | rw:u8 (1=set, 0=read) | data`. Reads send zero-filled data of the same size.

| cmd | name | data (set) | notes |
|---|---|---|---|
| 0x1001 | light (brightness) | f32 | float percent, e.g. 50.0 [V layout; range 0–100 per app] |
| 0x100B | light + mode | f32, i8 mode | mode 1=CCT, 2=RGB, 3=HSI [V] |
| 0x1002 | color temp | u16 Kelvin | [V layout; Kelvin I] |
| 0x1003 | RGB | u16 r,g,b | [V layout; range G (probably 0–255 or 0–1000)] |
| 0x1004 | hue | f32 | [V layout; degrees I] |
| 0x1005 | saturation | f32 | [V layout; % I] |
| 0x1006 | CMY / G-M | i8 | GM offset [V layout] |
| 0x1007 | chromaticity | u8 gamut, f32 x, f32 y | [V] |
| 0x1008 | sleep | u8: **1 = sleep/off, 0 = awake/on** | app: `sleep(id, z?1:0)` [V] |
| 0x1009 | max mode | u8 | [V] |
| 0x100A | HSI2 | f32 hue, f32 sat, u16 cct | [V layout] |

Composite client calls (each sends several frames, queued) [V]:
- `SetCCT(id, bright, cct)` = 0x1002(cct), then 0x100B(bright, mode=1).
- `SetCCT(id, bright, cct, gm)` = SetCCT(...), then 0x1006(gm).
- `SetHSI(id, intensity, hue, sat)` = 0x1005(sat), 0x1004(hue), then 0x100B(intensity, 3).
- `SetRGB(id, bright, r, g, b)` = 0x1003(r,g,b), then 0x100B(bright, 2).
- `setLightNative(id, f)` = 0x1001(f), with no mode.

### 3b. Per-device common commands (`CommonCmdParser::PackUint16PayloadRequest`): payload = `id:u16` only, with no rw byte [V]
| 0x1101 identify | 0x1201 voltage(id) | 0x1202 firmware version(id) | 0x1203 device mode(id) |

### 3c. Connected-node queries (no payload; apply to the GATT-connected light) [V]
| 0x2001 voltage | 0x2002 MTU | 0x2003 device info | 0x2004 extra info | 0x2005 device id | 0x8001 firmware version |

### 3d. Network / group management (GroupParser) [V]
| cmd | payload | meaning |
|---|---|---|
| 0x0006 | id:u16, 0x0000:u16 | register (`PackRegisterToDefualtGroup`): assigns the ZY device id to the connected light (+ default group 0) |
| 0x0003 | id:u16 | remove device (unpair). An alternative string form exists (payload = NUL-terminated string) |
| 0x0004 | id:u16, group:u16 | add to group |
| 0x0005 | id:u16, group:u16 | remove from group |

## 4. The "id" field [V in Java, I for semantics]
- It is **not the mesh unicast address**. The app allocates ZY device ids from `AtomicInteger(32768)`, so **devices are 0x8000, 0x8001, ...**. Group ids come from a separate counter starting at **1** (0x0001...). `ZYLightClient::IsGroupId(id)` = `!(id & 0x8000)` [V]. No 0xFFFF or 0xC000 handling appears anywhere in the native code.
- The id is written into the light once during pairing by `register` (cmd 0x0006), after the mesh provisioning and AppKey add plus getInfo, getFirmwareVersion and getVoltage (the Java `tryDoRegisterNative` runs only once all three have succeeded). The log string reads "user registration, device number 0x%04x, current device 0xffff". [V]
- **Register is not a per-connection handshake.** It is a one-time pairing step. On a later connection the app goes straight to commands (on reconnect it only calls getFirmwareVersion). [V Java flow] To control lights the app has already paired, read the id with `0x2005` (GetDeviceId, reply payload `u16 id`) from the connected node, or reuse ids 0x8000+. Commands addressed to other lights' ids are relayed over the lights' own mesh by the connected node. [I]
- Sending to a group id (for example the default group 0 from register) presumably reaches every member. [I/G]

## 5. Responses / notifications
Same frame format. Replies carry the **same seq** as the request; the client matches callbacks by seq. [V]
- 0x10xx replies: payload = `id:u16 | byte | value`, with the value at offset 3 and the same encoding as the set (for example 0x1001: f32 at +3 → "value"; id → "deviceId"). Byte 2 is not inspected (probably an rw echo or status). [V offsets, G byte2]
- Unsolicited frames with `cmd>>12 == 1` go to `FunctionalParser::Parse` (OnLightChanged(id,f32@3), OnColorTempChanged(id,u16@3), OnRGBChanged(u16@3,5,7), OnHue/OnSat(f32@3), OnCMY(u8@3), OnChmcoor(u8@3,f32@4,f32@8)). [V]
- 0x1201 (heartbeat / voltage report): `id:u16, voltage:u8`. It also refreshes the online timestamp (online state is tracked locally from these; `subscribeOnlineStat` is local only). [V/I]
- 0x2001: `voltage:u8`. 0x2002: `mtu:u16`. 0x2005: `deviceId:u16`. 0x8001: NUL-terminated version string. 0x1202: `id:u16`, then a string. [V]
- 0x2003 device info: consecutive NUL-terminated strings, logged as unique code, internal codename, model, hardware spec. Mapped to keys serialNo, generation, model, specification. [V keys, I order]

## 6. Worked examples (seq shown explicitly)
```
set brightness 50% on 0x8000 (seq 1):   24 3C 0D 00 00 01 01 00 01 10 00 80 01 00 00 48 42 39 9F
set CCT 5600K (seq 2):                  24 3C 0B 00 00 01 02 00 02 10 00 80 01 E0 15 6B 6B
brightness 50% + CCT mode (seq 3):      24 3C 0E 00 00 01 03 00 0B 10 00 80 01 00 00 48 42 01 5C C9
sleep/off (seq 4):                      24 3C 0A 00 00 01 04 00 08 10 00 80 01 01 1C F5
wake/on (seq 5):                        24 3C 0A 00 00 01 05 00 08 10 00 80 01 00 EE A2
read brightness (seq 6):                24 3C 0D 00 00 01 06 00 01 10 00 80 00 00 00 00 00 36 F0
identify (seq 7):                       24 3C 08 00 00 01 07 00 01 11 00 80 4F E3
get device id (seq 8):                  24 3C 06 00 00 01 08 00 05 20 05 F4
get device info (seq 9):                24 3C 06 00 00 01 09 00 03 20 17 28
register id 0x8000 (seq 10):            24 3C 0A 00 00 01 0A 00 06 00 00 80 00 00 E4 CC
remove device 0x8000 (seq 11):          24 3C 08 00 00 01 0B 00 03 00 00 80 97 71
RGB 255,0,0 (seq 12):                   24 3C 0F 00 00 01 0C 00 03 10 00 80 01 FF 00 00 00 00 00 A5 88
```
Reference encoder and parser: `zylight.py` (in this folder). Run `python3 -I zylight.py` to print the examples above.

## 7. Key addresses (libzylink.so)
CRC `zy::crc` 0x14d5b4 (table 0x99dae); `CalculateCRC16` 0xfec48 (same table at 0x94c46, init passed in, unused by light path);
ZYLightControllPacket::SerializeToData 0x18f8dc; ZYLightPacket ctor 0x18f5ac; FunctionalPacket ctor 0x168498;
FunctionalParser::Pack* 0x1686e0–0x16a090; GroupParser 0x16a314–0x16ae00; DeviceInfoParser::Pack* 0x165904;
ZYLightParser::OnDataReceived 0x18fb1c; BaseClient::SendPacket(CommandMessage) 0xfb7c8 → listener OnLinkDataSend (ZYCLightListener 0x197ff4).

## Corrections from testing on a PL103 (2026-10-16)
- **0x1008 is power enable, not sleep:** `1` = on, `0` = off, for both set and read. The SDK calls it "sleep", but the app's caller (`DeviceManagerRepository.D`, logged as "执行enable") passes `true` for on. Confirmed on hardware.
- A light whose pairing stopped after mesh provisioning reports device id `0x0000` to `0x2005`. Sending `register` (0x0006) then works, and the light acknowledges with status `00`.
- Set commands (rw=1) get no reply. Read commands do.
- Pacing, as implemented in VegaBar after review: writes of 0x1001/0x1002 ≥ 100 ms apart, 0x1008 ≥ 1 s apart, 0x1101/0x0006/0x0003 ≥ 2 s apart; reads unpaced; ≤ 20 frames/s overall. These are VegaBar's own limits, not requirements of the light.
