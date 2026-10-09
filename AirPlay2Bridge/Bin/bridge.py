#!/usr/bin/env python3
"""AirPlay 2 bridge: squeezelite (PCM stdout) -> pyatv -> HomePod OS 27+.

Based on cayco/cayco-squeezelite-airplay2-bridge (LMS-Raop issue #57 workaround).
One process per HomePod. Managed by LMS plugin AirPlay2Bridge (variant B).
Usage: bridge.py <player_name> <player_mac> <airplay_id> <homepod_ip> <lms_ip> [lms_cli_port]
  airplay_id: device unique id (AA:BB:..:FF hex or 12-16 hex chars); empty => scan by IP only
"""
import array
import asyncio
import ipaddress
import logging
import os
import signal
import sys
import time

import pyatv
from pyatv.const import Protocol
from pyatv.conf import AppleTV, ManualService
from pyatv.protocols.raop.audio_source import AudioSource
import pyatv.protocols.raop as raop
import pyatv.protocols.raop.audio_source as audio_source

logging.basicConfig(level=os.environ.get("LOGLEVEL", "INFO").upper(),
                    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s")
_LOGGER = logging.getLogger("bridge")

IDLE_TIMEOUT = float(os.environ.get("IDLE_TIMEOUT", "30.0"))
MAX_BUFFER_BYTES = int(os.environ.get("MAX_BUFFER_BYTES", "264600"))  # ~1.5s
PREBUFFER_BYTES = int(os.environ.get("PREBUFFER_BYTES", "70560"))    # ~400ms
RAOP_PORT = 7000
# Force ManualService with explicit AP2 props (bypass mDNS TXT records)
FORCE_MANUAL = os.environ.get("FORCE_MANUAL", "") == "1"

# Explicit AirPlay 2 RAOP TXT props so pyatv selects AirPlayV2 + TRANSIENT
# credentials (HAP Pair-Verify + ChaCha20). Empty {} => unencrypted AirPlayV1
# which HomePodOS 27+ rejects (the root cause of issue #57).
RAOP_AIRPLAY2_PROPS = {
    "cn": "0,1,2,3",
    "da": "true",
    "et": "0,3,5",
    "ft": "0x4A7FCA00,0x3C354BD0",
    "sf": "0xb8404",
    "md": "0,1,2",
    "am": "AudioAccessory5,1",
    "tp": "UDP",
    "vn": "65537",
    "vs": "980.77.2",
    "ov": "27.0",
    "vv": "1",
}

# Monkeypatch open_source to accept custom AudioSource
_orig_open = raop.open_source
async def _my_open(source, sample_rate, channels, sample_size):
    if isinstance(source, AudioSource):
        return source
    return await _orig_open(source, sample_rate, channels, sample_size)
raop.open_source = _my_open
audio_source.open_source = _my_open


def le2be(chunk: bytes) -> bytes:
    """16-bit LE PCM -> BE (RAOP wire format)."""
    if len(chunk) % 2 != 0:
        chunk = chunk[:-1]
    arr = array.array("h", chunk)
    arr.byteswap()
    return arr.tobytes()


class RingBufferAudioSource(AudioSource):
    """On-demand jitter buffer: squeezelite -> AirPlay 2.
    Consumed by pyatv at 1.0x realtime; NO_FRAMES on idle => clean teardown."""

    def __init__(self, bridge):
        self.bridge = bridge
        self.buffer = bridge.audio_buffer
        self.running = True
        self.buffering = len(self.buffer) < PREBUFFER_BYTES
        if not self.buffering:
            _LOGGER.info("%s: pre-buffer already filled (%d B)", bridge.name, len(self.buffer))

    async def readframes(self, nframes: int) -> bytes:
        if not self.running or self.bridge.is_idle:
            return AudioSource.NO_FRAMES
        needed = nframes * 4  # 16-bit stereo = 4 B/frame
        if self.buffering:
            if len(self.buffer) >= PREBUFFER_BYTES:
                self.buffering = False
                _LOGGER.info("%s: pre-buffer filled (%d B), streaming", self.bridge.name, len(self.buffer))
            else:
                return b"\x00" * needed
        if len(self.buffer) < needed:
            return b"\x00" * needed
        chunk = bytes(self.buffer[:needed])
        del self.buffer[:needed]
        return chunk

    async def close(self):
        self.running = False

    async def get_metadata(self):
        from pyatv.interface import MediaMetadata
        return MediaMetadata()

    @property
    def sample_rate(self) -> int:
        return 44100

    @property
    def channels(self) -> int:
        return 2

    @property
    def sample_size(self) -> int:
        return 2  # bytes per sample (16-bit)

    @property
    def duration(self) -> int:
        return 0  # live stream, unknown


class HomePodBridge:
    def __init__(self, name, mac, airplay_id, host, lms_ip, lms_cli=9090):
        self.name = name
        self.mac = mac
        self.mac_lms = mac.replace(":", "").lower()
        self.airplay_id = airplay_id or None
        self.host = host
        self.lms_ip = lms_ip
        self.lms_cli = lms_cli
        self.running = True
        self.is_idle = True
        self.is_streaming = False
        self.current_volume = 30.0
        self.audio_buffer = bytearray()
        self.last_audio_time = 0.0
        self.wake_event = asyncio.Event()
        self.proc = None   # squeezelite
        self.atv = None    # pyatv AppleTV
        self._cli_writer = None  # LMS CLI subscription (closed on stop)

    # ---------- LMS CLI ----------
    async def lms_cli_open(self):
        return await asyncio.open_connection(self.lms_ip, self.lms_cli)

    async def lms_cli_one(self, cmd):
        try:
            r, w = await asyncio.wait_for(self.lms_cli_open(), 5)
            w.write(f"{cmd}\n".encode()); await w.drain()
            try:
                line = await asyncio.wait_for(r.readline(), 5)
            except asyncio.TimeoutError:
                line = b""
            w.close()
            return line.decode(errors="replace").strip()
        except Exception as e:
            _LOGGER.warning("%s: lms_cli_one(%r): %s", self.name, cmd, e)
            return ""

    # ---------- squeezelite ----------
    async def start_squeezelite(self):
        sq_bin = os.environ.get("SQUEEZELITE_BIN", "/usr/local/bin/squeezelite-ap2")
        if not os.path.exists(sq_bin):
            sq_bin = "squeezelite"  # fallback to system binary
        cmd = [sq_bin, "-n", self.name, "-m", self.mac,
               "-s", self.lms_ip, "-o", "-", "-a", "16",
               "-r", "44100:44100", "-b", "500:2000", "-d", "all=warn"]
        _LOGGER.info("%s: squeezelite %s", self.name, " ".join(cmd))
        self.proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE)  # stderr inherits bridge log

    async def drain_squeezelite_stdout(self):
        """Read PCM; detect silence; apply backpressure during handshake."""
        while self.running:
            try:
                chunk = await asyncio.wait_for(self.proc.stdout.read(4096), timeout=1.0)
            except asyncio.TimeoutError:
                chunk = b""
            if chunk and any(chunk):
                self.audio_buffer.extend(le2be(chunk))
                self.last_audio_time = time.monotonic()
                if self.is_idle:
                    _LOGGER.info("%s: audio detected (%d B buffered)", self.name, len(self.audio_buffer))
                    self.is_idle = False
                    self.wake_event.set()
                # backpressure: squeezelite throttles via blocked stdout pipe
                while (self.running and not self.is_idle
                       and len(self.audio_buffer) >= MAX_BUFFER_BYTES):
                    await asyncio.sleep(0.05)
            else:
                # silence or no data: nothing to buffer
                if not self.is_idle and (time.monotonic() - self.last_audio_time) > IDLE_TIMEOUT:
                    _LOGGER.info("%s: idle %.0fs -> teardown AirPlay", self.name, IDLE_TIMEOUT)
                    self.is_idle = True  # readframes() returns NO_FRAMES -> stream closes
                    self.audio_buffer.clear()
            await asyncio.sleep(0)

    # ---------- AirPlay 2 ----------
    async def find_conf(self, force_scan):
        """mDNS scan first; ManualService with AP2 props as fallback."""
        loop = asyncio.get_running_loop()
        if not FORCE_MANUAL:
            try:
                kwargs = {"protocol": Protocol.RAOP, "timeout": 5}
                if self.airplay_id:
                    kwargs["identifier"] = self.airplay_id
                elif self.host:
                    kwargs["hosts"] = [self.host]
                devs = await pyatv.scan(loop, **kwargs)
                if devs:
                    _LOGGER.info("%s: scan found '%s' (%s)", self.name, devs[0].name, devs[0].address)
                    return devs[0]
            except Exception as e:
                _LOGGER.warning("%s: scan failed: %s", self.name, e)
        if not self.host:
            return None
        _LOGGER.info("%s: falling back to ManualService %s:%d", self.name, self.host, RAOP_PORT)
        conf = AppleTV(ipaddress.ip_address(self.host), self.name)
        ident = self.airplay_id or self.mac
        conf.add_service(ManualService(ident, Protocol.RAOP, RAOP_PORT,
                                       properties=RAOP_AIRPLAY2_PROPS))
        return conf

    async def run_airplay(self):
        while self.running:
            if self.is_idle:
                self.wake_event.clear()
                await self.wake_event.wait()
                if not self.running:
                    break
            conf = await self.find_conf(force_scan=False)
            if not conf:
                _LOGGER.warning("%s: AirPlay target not found, retry in 5s", self.name)
                self.is_idle = True
                await asyncio.sleep(5)
                continue
            try:
                _LOGGER.info("%s: connecting to %s ...", self.name, conf.address)
                self.atv = await pyatv.connect(conf, asyncio.get_running_loop())
                try:
                    await self.atv.audio.set_volume(self.current_volume)
                    _LOGGER.info("%s: initial volume -> %.1f (device reports %.1f)",
                                 self.name, self.current_volume, self.atv.audio.volume)
                except Exception as e:
                    _LOGGER.warning("%s: initial volume failed: %s", self.name, e)
                source = RingBufferAudioSource(self)
                self.is_streaming = True
                _LOGGER.info("%s: AirPlay 2 streaming started", self.name)

                async def _enforce_volume():
                    for delay in (1.5, 4.0):
                        await asyncio.sleep(delay)
                        if self.is_streaming and self.atv:
                            try:
                                await self.atv.audio.set_volume(self.current_volume)
                            except Exception as ve:
                                _LOGGER.debug("%s: volume re-send: %s", self.name, ve)

                vol_task = asyncio.create_task(_enforce_volume())
                try:
                    await self.atv.stream.stream_file(source)
                finally:
                    vol_task.cancel()
                _LOGGER.info("%s: stream closed (idle=%s)", self.name, self.is_idle)
            except Exception as e:
                _LOGGER.error("%s: AirPlay error: %s; reconnect in 3s", self.name, e)
                self.is_idle = True
                await asyncio.sleep(3)
                continue
            finally:
                self.is_streaming = False
                if self.atv:
                    try:
                        self.atv.close()
                    except Exception:
                        pass
                    self.atv = None
            # stream ended because idle -> loop and wait for wake_event

    # ---------- LMS volume sync ----------
    async def sync_volume_lms(self):
        # dVC=0: LMS mixer does not attenuate PCM (avoid double attenuation with
        # HomePod volume); re-sent on every reconnect since player may register late
        while self.running:
            try:
                await self.lms_cli_one(f"{self.mac_lms} playerpref digitalVolumeControl 0")
                r, w = await self.lms_cli_open()
                self._cli_writer = w
                w.write(f"{self.mac_lms} mixer volume ?\n".encode()); await w.drain()
                w.write("subscribe mixer\n".encode()); await w.drain()
                _LOGGER.info("%s: subscribed to LMS mixer events", self.name)
                while self.running:
                    line = await r.readline()
                    if not line:
                        break
                    text = line.decode(errors="replace").strip()
                    if text.startswith(self.mac_lms) and "mixer volume" in text:
                        try:
                            vol = float(text.rsplit(" ", 1)[-1])
                            self.current_volume = max(0.0, min(100.0, vol))
                            if self.atv:
                                await self.atv.audio.set_volume(self.current_volume)
                                _LOGGER.info("%s: volume=%.0f", self.name, self.current_volume)
                        except ValueError:
                            pass
                w.close()
            except Exception as e:
                _LOGGER.warning("%s: volume sync: %s", self.name, e)
            await asyncio.sleep(5)

    async def run(self):
        await self.start_squeezelite()
        try:
            await asyncio.gather(self.drain_squeezelite_stdout(),
                                 self.run_airplay(),
                                 self.sync_volume_lms())
        finally:
            self.running = False
            self.is_streaming = False
            if self.proc:
                try:
                    self.proc.terminate()
                    await self.proc.wait()
                except Exception:
                    pass
            if self.atv:
                try:
                    self.atv.close()
                except Exception:
                    pass

    def stop(self):
        self.running = False
        self.is_idle = False
        self.wake_event.set()
        if self.proc:
            try:
                self.proc.terminate()
            except Exception:
                pass
        if self._cli_writer:
            try:
                self._cli_writer.close()  # unblocks volume_monitor readline
            except Exception:
                pass
        # hard safety: never survive SIGTERM by more than 5 s
        try:
            asyncio.get_running_loop().call_later(5, os._exit, 0)
        except RuntimeError:
            pass


async def main():
    if len(sys.argv) < 6:
        print("Usage: bridge.py <name> <mac> <airplay_id> <homepod_ip> <lms_ip> [cli_port]", file=sys.stderr)
        sys.exit(2)
    name, mac, airplay_id, host, lms_ip = sys.argv[1:6]
    cli_port = int(sys.argv[6]) if len(sys.argv) > 6 else 9090
    br = HomePodBridge(name, mac, airplay_id, host, lms_ip, cli_port)
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, br.stop)
    await br.run()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (asyncio.CancelledError, KeyboardInterrupt):
        pass
