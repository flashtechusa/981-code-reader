#!/usr/bin/env python3
"""
porsche981_srs.py  -  ELM327 / OBDLink UDS tool for the Porsche 981 airbag (POSIP) module
==========================================================================================

Three sub-commands, in order of how you'll use them:

  scan    Discover which module is the airbag ECU.  READ-ONLY: sends only TesterPresent
          (0x3E), ReadDTCInformation (0x19 0x02) and ReadDataByIdentifier (0x22) to
          candidate addresses.  Nothing is written, nothing is cleared.

  read    Identify + read DTCs from ONE address you give it.  READ-ONLY.

  clear   Read DTCs, then ClearDiagnosticInformation (0x14 FF FF FF) on ONE address,
          after you type CLEAR at the prompt.  Refuses powertrain / functional IDs.

Transport (pick one):
  --tcp HOST:PORT      Wi-Fi adapters        e.g. --tcp 192.168.0.10:35000
  --serial PORT        Bluetooth Classic SPP / USB   e.g. --serial COM5
                                                       --serial /dev/rfcomm0
                                                       --serial /dev/tty.OBDLinkMX-SPP
  (BLE-only adapters and iOS need a different transport - see README notes.)

Typical session (ignition ON, engine OFF, car not moving, battery healthy):

  python porsche981_srs.py --serial COM5 scan                 # 11-bit 0x700-0x7FF + 29-bit
  python porsche981_srs.py --serial COM5 read  --addr 715     # whatever scan found
  python porsche981_srs.py --serial COM5 clear --addr 715

Addresses are given as the REQUEST id:
  11-bit:  "715"            (response id discovered automatically, or --resp 77F)
  29-bit:  "18DA15F1"       (response id is derived: 18DAF115)

Design notes
------------
* The adapter is run with AT CAF0 (raw frames, PCI bytes visible) + AT CFC1 (adapter still
  sends ISO-TP flow control).  We reassemble ISO-TP ourselves - this is more predictable than
  the adapter's CAF1 formatting, which prints single and multi-frame replies differently.
* Every UDS request passes through one choke point, Uds.request(), which enforces a
  service-ID allow-list.  There is no code path that can send 0x27 (SecurityAccess),
  0x2E (WriteDataByIdentifier), 0x31 (RoutineControl), 0x34-0x38 (download/upload),
  0x11 (ECUReset) or 0x10 0x02 (programming session).  If you want those, this is the
  wrong tool.
* Clearing is only possible on the single address you pass on the command line, and only
  after the module answered identification + DTC read in this same session.
"""

import argparse
import re
import socket
import sys
import time

# --------------------------------------------------------------------------------------
# UDS constants
# --------------------------------------------------------------------------------------

SID_SESSION      = 0x10
SID_CLEAR_DTC    = 0x14
SID_READ_DTC     = 0x19
SID_READ_DID     = 0x22
SID_TESTER_PRES  = 0x3E

# The ONLY services this script is permitted to transmit.
ALLOWED_SIDS = {SID_SESSION, SID_CLEAR_DTC, SID_READ_DTC, SID_READ_DID, SID_TESTER_PRES}
# DiagnosticSessionControl sub-functions permitted (never 0x02 programming).
ALLOWED_SESSIONS = {0x01, 0x03}

NRC = {
    0x10: "generalReject",
    0x11: "serviceNotSupported",
    0x12: "subFunctionNotSupported",
    0x13: "incorrectMessageLengthOrInvalidFormat",
    0x14: "responseTooLong",
    0x21: "busyRepeatRequest",
    0x22: "conditionsNotCorrect  (ignition on? engine off? speed 0? voltage ok?)",
    0x24: "requestSequenceError",
    0x31: "requestOutOfRange",
    0x33: "securityAccessDenied  (this module wants SecurityAccess 0x27 - this tool will NOT do that)",
    0x35: "invalidKey",
    0x36: "exceedNumberOfAttempts",
    0x37: "requiredTimeDelayNotExpired",
    0x72: "generalProgrammingFailure",
    0x78: "requestCorrectlyReceived-ResponsePending",
    0x7E: "subFunctionNotSupportedInActiveSession",
    0x7F: "serviceNotSupportedInActiveSession",
}

# Data identifiers that are harmless to read and help label a module.
IDENT_DIDS = {
    0xF187: "spare part number",
    0xF191: "ECU hardware number",
    0xF197: "system name",
    0xF189: "software version",
    0xF19E: "ODX / ASAM file",
}

# 11-bit IDs we never clear on, and skip in the default scan.
FUNCTIONAL_11 = 0x7DF                       # broadcast to every ECU - never
POWERTRAIN_11 = set(range(0x7E0, 0x7E8))    # DME / PDK legislated range
RESPONSE_11   = set(range(0x7E8, 0x7F0))    # response IDs - pointless to address
# 29-bit normal-fixed: 0x18DA <target> <source>.  Functional = 0x18DB33F1.
FUNCTIONAL_29 = 0x18DB33F1
POWERTRAIN_29_TARGETS = {0x10, 0x18}        # conventional engine / transmission targets


# --------------------------------------------------------------------------------------
# Transports
# --------------------------------------------------------------------------------------

class TcpTransport:
    """Wi-Fi ELM327 clones expose a raw TCP socket (commonly 192.168.0.10:35000)."""

    def __init__(self, host, port, timeout=1.0):
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.settimeout(timeout)

    def write(self, data: bytes):
        self.sock.sendall(data)

    def read(self, n=4096) -> bytes:
        try:
            return self.sock.recv(n)
        except socket.timeout:
            return b""

    def set_timeout(self, t):
        self.sock.settimeout(t)

    def close(self):
        self.sock.close()


class SerialTransport:
    """Bluetooth Classic (SPP) or USB adapters appear as a serial port."""

    def __init__(self, port, baud=115200, timeout=1.0):
        try:
            import serial  # pyserial
        except ImportError:
            sys.exit("pyserial not installed:  pip install pyserial")
        self.ser = serial.Serial(port, baud, timeout=timeout)

    def write(self, data: bytes):
        self.ser.write(data)

    def read(self, n=4096) -> bytes:
        return self.ser.read(self.ser.in_waiting or 1)

    def set_timeout(self, t):
        self.ser.timeout = t

    def close(self):
        self.ser.close()


# --------------------------------------------------------------------------------------
# ELM327 layer
# --------------------------------------------------------------------------------------

class ElmError(Exception):
    pass


class Elm327:
    def __init__(self, transport, verbose=False):
        self.t = transport
        self.verbose = verbose
        self.bits = 11          # current protocol addressing width
        self.req_id = None
        self.resp_id = None

    # ---- low level -------------------------------------------------------------------

    def cmd(self, s: str, timeout=2.0) -> str:
        """Send one line, return everything up to the '>' prompt (prompt stripped)."""
        if self.verbose:
            print(f"   >> {s}")
        self.t.write((s + "\r").encode("ascii"))
        buf = b""
        deadline = time.time() + timeout
        self.t.set_timeout(0.2)
        while time.time() < deadline:
            chunk = self.t.read()
            if chunk:
                buf += chunk
                if b">" in buf:
                    break
        text = buf.decode("ascii", errors="replace").replace("\r", "\n")
        text = text.replace(">", "").strip()
        if self.verbose:
            for line in text.splitlines():
                print(f"   << {line}")
        return text

    def init(self):
        self.cmd("ATZ", timeout=3.0)      # reset
        time.sleep(0.5)
        self.cmd("ATE0")                  # echo off
        self.cmd("ATL0")                  # no linefeeds
        self.cmd("ATS1")                  # keep spaces (easier to read when verbose)
        self.cmd("ATH1")                  # print headers - we need the response ID
        self.cmd("ATCAF0")                # raw frames, we handle ISO-TP
        self.cmd("ATCFC1")                # ... but adapter still sends flow control
        self.cmd("ATAT0")                 # adaptive timing off so ATST is honoured
        self.cmd("ATAL")                  # allow long (>7 byte) messages
        ident = self.cmd("ATI")
        volts = self.cmd("ATRV")
        print(f"Adapter: {ident}   battery: {volts}")
        try:
            v = float(re.sub(r"[^\d.]", "", volts))
            if v < 12.0:
                print("WARNING: battery below 12.0 V. Low voltage is a classic cause of NRC 0x22 "
                      "and of spurious airbag faults. Put a charger on it.")
        except ValueError:
            pass

    def set_bits(self, bits: int):
        """ISO 15765-4 CAN 500 kbps: protocol 6 = 11-bit, 7 = 29-bit."""
        self.bits = bits
        self.cmd("ATSP6" if bits == 11 else "ATSP7")

    def set_timeout_ms(self, ms: int):
        # ATST takes hex, units of 4 ms, max 0xFF (~1.02 s)
        self.cmd(f"ATST{min(0xFF, max(1, ms // 4)):02X}")

    # ---- addressing -------------------------------------------------------------------

    def set_target(self, req_id: int, resp_id=None, wide_filter=False):
        """
        Point the adapter at one ECU.
          11-bit: ATSH 7xx ;  receive filter either exact (ATCRA) or wide (0x700-0x7FF)
          29-bit: ATCP 18 + ATSH DA xx F1 ; receive 18DAF1xx or wide (any 18DAF1xx)
        """
        self.req_id = req_id
        if self.bits == 11:
            self.cmd(f"ATSH{req_id:03X}")
            if wide_filter:
                self.cmd("ATCF700")
                self.cmd("ATCM700")       # accept 0x700..0x7FF
                self.resp_id = None
            else:
                self.resp_id = resp_id if resp_id is not None else req_id + 8
                self.cmd(f"ATCRA{self.resp_id:03X}")
        else:
            prio = (req_id >> 24) & 0xFF
            lo = req_id & 0xFFFFFF
            self.cmd(f"ATCP{prio:02X}")
            self.cmd(f"ATSH{lo:06X}")
            target = (req_id >> 8) & 0xFF
            source = req_id & 0xFF
            if wide_filter:
                self.cmd(f"ATCF{(prio << 24) | 0x00DA0000 | (source << 8):08X}")
                self.cmd("ATCM1FFFFF00")  # any target replying to our source address
                self.resp_id = None
            else:
                self.resp_id = (prio << 24) | 0x00DA0000 | (source << 8) | target
                self.cmd(f"ATCRA{self.resp_id:08X}")

    # ---- raw CAN send / receive -------------------------------------------------------

    def send_frames_and_collect(self, payload: bytes, timeout=1.5) -> dict:
        """
        Send one single-frame ISO-TP request (payload <= 7 bytes) and return
        {response_can_id: reassembled_uds_bytes} for every ECU that answered.
        """
        if len(payload) > 7:
            raise ElmError("multi-frame requests not supported (and not needed here)")
        frame = bytes([len(payload)]) + payload
        frame = frame + b"\x00" * (8 - len(frame))          # explicit 8-byte padding
        text = self.cmd(" ".join(f"{b:02X}" for b in frame), timeout=timeout)
        return self._parse_frames(text)

    def _parse_frames(self, text: str) -> dict:
        """Group raw frames by CAN ID and reassemble ISO-TP (SF / FF / CF)."""
        msgs = {}     # id -> {"len": n, "data": bytearray}
        hdr_len = 3 if self.bits == 11 else 8
        for line in text.splitlines():
            line = line.strip()
            if not line or any(k in line for k in ("NO DATA", "SEARCHING", "STOPPED", "BUS INIT",
                                                      "CAN ERROR", "UNABLE", "ERROR", "?")):
                if "CAN ERROR" in line or "UNABLE" in line:
                    print(f"   adapter: {line}")
                continue
            hexstr = line.replace(" ", "")
            if not re.fullmatch(r"[0-9A-Fa-f]+", hexstr) or len(hexstr) <= hdr_len:
                continue
            can_id = int(hexstr[:hdr_len], 16)
            data = bytes.fromhex(hexstr[hdr_len:]) if len(hexstr[hdr_len:]) % 2 == 0 else b""
            if not data:
                continue
            pci_type = data[0] >> 4
            if pci_type == 0:                      # single frame
                n = data[0] & 0x0F
                msgs[can_id] = {"len": n, "data": bytearray(data[1:1 + n])}
            elif pci_type == 1:                    # first frame
                n = ((data[0] & 0x0F) << 8) | data[1]
                msgs[can_id] = {"len": n, "data": bytearray(data[2:])}
            elif pci_type == 2 and can_id in msgs:  # consecutive frame
                msgs[can_id]["data"] += data[1:]
            # pci_type 3 = flow control from the ECU - ignore
        return {cid: bytes(m["data"][:m["len"]]) for cid, m in msgs.items()}


# --------------------------------------------------------------------------------------
# UDS layer with the safety choke point
# --------------------------------------------------------------------------------------

class UdsError(Exception):
    pass


class Uds:
    def __init__(self, elm: Elm327):
        self.elm = elm

    def request(self, payload: bytes, timeout=1.5, expect_sid=None) -> dict:
        """
        THE single transmit path.  Enforces:
          - service ID allow-list
          - DiagnosticSessionControl only to default/extended
          - 0x14 never to functional / powertrain addresses
        Returns {can_id: response_bytes}.  Positive responses are checked by caller.
        """
        sid = payload[0]
        if sid not in ALLOWED_SIDS:
            raise UdsError(f"refusing to send service 0x{sid:02X} - not on the allow-list")
        if sid == SID_SESSION and (len(payload) < 2 or (payload[1] & 0x7F) not in ALLOWED_SESSIONS):
            raise UdsError("refusing to send a non default/extended diagnostic session")
        if sid == SID_CLEAR_DTC:
            self._assert_clear_target_ok(self.elm.req_id)
        return self.elm.send_frames_and_collect(payload, timeout=timeout)

    def _assert_clear_target_ok(self, req_id):
        if self.elm.bits == 11:
            if req_id == FUNCTIONAL_11:
                raise UdsError("refusing to clear via functional/broadcast ID 0x7DF")
            if req_id in POWERTRAIN_11:
                raise UdsError(f"refusing to clear on powertrain ID 0x{req_id:03X}")
        else:
            if req_id == FUNCTIONAL_29:
                raise UdsError("refusing to clear via functional 29-bit ID")
            if ((req_id >> 8) & 0xFF) in POWERTRAIN_29_TARGETS:
                raise UdsError(f"refusing to clear on powertrain 29-bit target 0x{req_id:08X}")

    # ---- helpers ----------------------------------------------------------------------

    @staticmethod
    def check(resp: bytes, sid: int):
        """Return payload after positive SID, or raise UdsError with decoded NRC."""
        if not resp:
            raise UdsError("no response")
        if resp[0] == 0x7F:
            nrc = resp[2] if len(resp) > 2 else 0
            raise UdsError(f"negative response to 0x{resp[1]:02X}: NRC 0x{nrc:02X} "
                           f"{NRC.get(nrc, 'unknown')}")
        if resp[0] != sid + 0x40:
            raise UdsError(f"unexpected response {resp.hex(' ').upper()}")
        return resp[1:]

    @staticmethod
    def is_pending(resp: bytes):
        return len(resp) >= 3 and resp[0] == 0x7F and resp[2] == 0x78

    def single(self, payload: bytes, timeout=1.5) -> bytes:
        """Request expecting exactly one responder (the configured target)."""
        resps = self.request(payload, timeout=timeout)
        if not resps:
            return b""
        if self.elm.resp_id is not None and self.elm.resp_id in resps:
            return resps[self.elm.resp_id]
        # wide filter or unexpected id: take the single answer if there is one
        if len(resps) == 1:
            return next(iter(resps.values()))
        raise UdsError(f"multiple responders: {[hex(k) for k in resps]}")

    def tester_present(self):
        try:
            self.request(bytes([SID_TESTER_PRES, 0x80]), timeout=0.3)  # suppress pos. resp.
        except UdsError:
            pass

    def read_did(self, did: int) -> bytes:
        r = self.single(bytes([SID_READ_DID, did >> 8, did & 0xFF]))
        return self.check(r, SID_READ_DID)[2:] if r else b""

    def read_dtcs(self, mask=0xFF):
        r = self.single(bytes([SID_READ_DTC, 0x02, mask]), timeout=2.0)
        body = self.check(r, SID_READ_DTC)          # 02 <availMask> [dtc(3) status(1)]*
        if len(body) < 2 or body[0] != 0x02:
            raise UdsError(f"unexpected ReadDTC body {body.hex(' ')}")
        recs = body[2:]
        out = []
        for i in range(0, len(recs) - 3, 4):
            dtc, status = recs[i:i + 3], recs[i + 3]
            out.append((dtc, status))
        return out


# --------------------------------------------------------------------------------------
# Presentation helpers
# --------------------------------------------------------------------------------------

def dtc_to_sae(dtc: bytes) -> str:
    letter = "PCBU"[dtc[0] >> 6]
    return f"{letter}{(dtc[0] >> 4) & 0x3}{dtc[0] & 0xF:X}{dtc[1]:02X}-{dtc[2]:02X}"


def status_bits(s: int) -> str:
    names = ["testFailed", "testFailedThisCycle", "pending", "confirmed",
             "notCompletedSinceClear", "failedSinceClear", "notCompletedThisCycle", "warningLamp"]
    return ",".join(n for i, n in enumerate(names) if s & (1 << i)) or "-"


def print_dtcs(dtcs):
    if not dtcs:
        print("   no DTCs stored")
        return
    for dtc, st in dtcs:
        print(f"   {dtc.hex().upper()}  ({dtc_to_sae(dtc)})  status 0x{st:02X}: {status_bits(st)}")


def ascii_or_hex(b: bytes) -> str:
    s = "".join(chr(c) if 32 <= c < 127 else "." for c in b)
    return s if s.replace(".", "") else b.hex(" ").upper()


def identify(uds: Uds) -> dict:
    """Read the identification DIDs that answer. Read-only."""
    info = {}
    for did, name in IDENT_DIDS.items():
        try:
            val = uds.read_did(did)
            if val:
                info[name] = ascii_or_hex(val)
        except UdsError:
            pass
    return info


def looks_like_airbag(info: dict, dtcs) -> bool:
    text = " ".join(info.values()).upper()
    if any(k in text for k in ("AIRBAG", "POSIP", "SRS", "RESTRAINT")):
        return True
    # Porsche airbag control units carry part numbers in the 9xx 618 xxx xx family.
    if re.search(r"9\d[0-9A-Z][\s.]?618[\s.]?\d{3}", text):
        return True
    # Body (B) codes freshly failed this cycle is the pattern an unplugged squib produces.
    return any(dtc[0] >> 6 == 2 and (st & 0x01) for dtc, st in dtcs)


# --------------------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------------------

def parse_addr(s: str):
    v = int(s, 16)
    return (29, v) if len(s) == 8 else (11, v)


def do_scan(elm: Elm327, uds: Uds, include_powertrain: bool, quick: bool):
    print("\n=== SCAN (read-only) ===")
    print("Ignition ON, engine OFF. This sends TesterPresent to each candidate, then "
          "ReadDTC / identification to anything that answers.\n")

    found = []

    # ---- 11-bit --------------------------------------------------------------------
    elm.set_bits(11)
    elm.set_timeout_ms(60)
    candidates = [0x715] if quick else list(range(0x700, 0x800))
    for rid in candidates:
        if rid == FUNCTIONAL_11 or rid in RESPONSE_11:
            continue
        if rid in POWERTRAIN_11 and not include_powertrain:
            continue
        elm.set_target(rid, wide_filter=True)
        resps = uds.request(bytes([SID_TESTER_PRES, 0x00]), timeout=0.4)
        for resp_id, data in resps.items():
            if data[:1] in (b"\x7e", b"\x7f"):
                print(f"  11-bit  req 0x{rid:03X} -> resp 0x{resp_id:03X}  {data.hex(' ').upper()}")
                found.append((11, rid, resp_id))
        sys.stdout.write(f"\r  probing 0x{rid:03X} ...")
        sys.stdout.flush()
    print()

    # ---- 29-bit normal fixed (tester = 0xF1) ------------------------------------------
    if not quick:
        elm.set_bits(29)
        elm.set_timeout_ms(60)
        for ta in range(0x00, 0x100):
            if ta in POWERTRAIN_29_TARGETS and not include_powertrain:
                continue
            rid = 0x18DA0000 | (ta << 8) | 0xF1
            elm.set_target(rid, wide_filter=True)
            resps = uds.request(bytes([SID_TESTER_PRES, 0x00]), timeout=0.4)
            for resp_id, data in resps.items():
                if data[:1] in (b"\x7e", b"\x7f"):
                    print(f"  29-bit  req 0x{rid:08X} -> resp 0x{resp_id:08X}  {data.hex(' ').upper()}")
                    found.append((29, rid, resp_id))
            sys.stdout.write(f"\r  probing 0x{rid:08X} ...")
            sys.stdout.flush()
        print()

    if not found:
        print("\nNothing answered. Check: ignition on? adapter on the right car? Some Porsche "
              "modules only answer behind the gateway after a session request - try "
              "--include-powertrain to confirm the DME answers at 0x7E0 at all.")
        return

    # ---- label every responder (still read-only) -------------------------------------
    print("\n=== Responders ===")
    elm.set_timeout_ms(400)
    for bits, rid, resp_id in found:
        elm.set_bits(bits)
        elm.set_target(rid, resp_id)
        info, dtcs = {}, []
        try:
            info = identify(uds)
            dtcs = uds.read_dtcs()
        except UdsError as e:
            info["note"] = str(e)
        flag = "  <== LIKELY AIRBAG / POSIP" if looks_like_airbag(info, dtcs) else ""
        addr = f"{rid:03X}" if bits == 11 else f"{rid:08X}"
        print(f"\n--addr {addr}   (resp 0x{resp_id:X}){flag}")
        for k, v in info.items():
            print(f"   {k:18s} {v}")
        print_dtcs(dtcs)

    print("\nNext: python porsche981_srs.py <transport> read --addr <the flagged one>")


def connect_target(elm: Elm327, uds: Uds, addr: str, resp: str):
    bits, rid = parse_addr(addr)
    elm.set_bits(bits)
    elm.set_timeout_ms(400)
    elm.set_target(rid, int(resp, 16) if resp else None)
    r = uds.single(bytes([SID_TESTER_PRES, 0x00]))
    if not r:
        raise UdsError(f"no answer from 0x{rid:X} (wrong id? ignition off? need --resp?)")
    uds.check(r, SID_TESTER_PRES)
    return bits, rid


def do_read(elm, uds, addr, resp):
    print("\n=== READ (read-only) ===")
    connect_target(elm, uds, addr, resp)
    info = identify(uds)
    for k, v in info.items():
        print(f"   {k:18s} {v}")
    dtcs = uds.read_dtcs()
    print("DTCs:")
    print_dtcs(dtcs)
    return info, dtcs


def do_clear(elm, uds, addr, resp):
    info, dtcs = do_read(elm, uds, addr, resp)

    if not looks_like_airbag(info, dtcs):
        print("\nThis module does not identify as the airbag unit and has no fresh B-codes.")
        ans = input("Type the address again to clear it anyway, or Enter to abort: ").strip().upper()
        if ans != addr.upper():
            print("aborted")
            return

    print("\nAbout to send ClearDiagnosticInformation 14 FF FF FF to this module ONLY.")
    print("Clearing does not fix anything: if the passenger squib connector is still open,")
    print("the POSIP re-detects it immediately and the lamp comes straight back.")
    if input("Type CLEAR to proceed: ").strip() != "CLEAR":
        print("aborted")
        return

    # Extended session is usually not required for 0x14 but some ECUs insist. Try it,
    # fall through to default session if refused.
    try:
        r = uds.single(bytes([SID_SESSION, 0x03]))
        uds.check(r, SID_SESSION)
        print("extended diagnostic session: OK")
    except UdsError as e:
        print(f"extended session not entered ({e}); trying in default session")
    uds.tester_present()

    elm.set_timeout_ms(1020)                      # max ATST - gives 0x78 pending room
    r = uds.single(bytes([SID_CLEAR_DTC, 0xFF, 0xFF, 0xFF]), timeout=3.0)
    tries = 0
    while uds.is_pending(r) and tries < 5:
        tries += 1
        print("   response pending (0x78) ... waiting")
        # The adapter stopped listening at the prompt; poll with TesterPresent so the
        # final 0x54 (or 0x7F) is captured on the way back.
        time.sleep(0.5)
        resps = uds.request(bytes([SID_TESTER_PRES, 0x00]), timeout=2.0)
        r = resps.get(elm.resp_id, b"")
        if r[:1] == b"\x7e":                      # only TP answered; assume clear done
            r = b""
            break

    if r[:1] == b"\x54":
        print("ClearDiagnosticInformation: POSITIVE (0x54)")
    elif r:
        try:
            uds.check(r, SID_CLEAR_DTC)
        except UdsError as e:
            print(f"ClearDiagnosticInformation FAILED: {e}")
            return
    else:
        print("no explicit 0x54 seen - verifying by re-reading DTCs")

    elm.set_timeout_ms(400)
    time.sleep(0.5)
    dtcs2 = uds.read_dtcs()
    print("DTCs after clear:")
    print_dtcs(dtcs2)
    if any(st & 0x01 for _, st in dtcs2):
        print("\nA fault is STILL testFailed -> the condition persists (connector open, "
              "resistance out of range, etc.). Fix the circuit, cycle ignition, clear again.")
    # back to default session
    try:
        uds.single(bytes([SID_SESSION, 0x01]))
    except UdsError:
        pass


# --------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    tr = ap.add_mutually_exclusive_group(required=False)
    tr.add_argument("--tcp", metavar="HOST:PORT", default=None,
                    help="Wi-Fi adapter (default if nothing given: 192.168.0.10:35000)")
    tr.add_argument("--serial", metavar="PORT", help="serial / Bluetooth SPP port, e.g. COM5")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("-v", "--verbose", action="store_true", help="print every AT/CAN exchange")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="discover modules (read-only)")
    s.add_argument("--include-powertrain", action="store_true")
    s.add_argument("--quick", action="store_true", help="only probe the VW-group airbag convention 0x715")

    for name in ("read", "clear"):
        p = sub.add_parser(name)
        p.add_argument("--addr", required=True, help="request id: 715 or 18DA15F1")
        p.add_argument("--resp", help="response id if not req+8 (11-bit only)")

    a = ap.parse_args()

    if a.serial:
        t = SerialTransport(a.serial, a.baud)
    else:
        host, port = (a.tcp or "192.168.0.10:35000").rsplit(":", 1)
        print(f"Connecting to adapter at {host}:{port} (be on the adapter's Wi-Fi) ...")
        try:
            t = TcpTransport(host, int(port))
        except OSError as e:
            sys.exit(f"could not reach the adapter: {e}\n"
                     "Join the adapter's Wi-Fi (usually WiFi_OBDII), tap 'stay connected' if your "
                     "phone warns about no internet, and make sure the switch is on HS-CAN.")

    elm = Elm327(t, verbose=a.verbose)
    uds = Uds(elm)
    try:
        elm.init()
        if a.cmd == "scan":
            do_scan(elm, uds, a.include_powertrain, a.quick)
        elif a.cmd == "read":
            do_read(elm, uds, a.addr, a.resp)
        elif a.cmd == "clear":
            do_clear(elm, uds, a.addr, a.resp)
    except (UdsError, ElmError) as e:
        print(f"\nERROR: {e}")
    finally:
        try:
            elm.cmd("ATPC")      # protocol close
        except Exception:
            pass
        t.close()


if __name__ == "__main__":
    main()
