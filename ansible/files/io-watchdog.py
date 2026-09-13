#!/usr/bin/env python3
"""io-watchdog.py — feeds /dev/watchdog only if disk I/O is confirmed healthy.

Background: systemd's own RuntimeWatchdogSec pets /dev/watchdog from PID1's
internal event loop, which never touches disk - so it keeps the hardware
watchdog happy even during a D-state storage pile-up (hung Longhorn/iSCSI
mount on the node's NVMe) that leaves everything needing fork()/disk I/O
(SSH sessions, containerd, even a periodically-forked check script) stuck.
See k3s-06a incidents 2026-07-28 and 2026-09-13.

This replaces that with a single long-lived process that only pets the
watchdog when a real disk I/O round-trip has succeeded recently:

- One background thread, created ONCE at startup, loops forever doing a
  small write+fsync+read+verify against a heartbeat file on the local
  filesystem (same NVMe partition Longhorn/OS data lives on). Because it's
  created once at boot rather than re-forked every cycle, a later D-state
  hang just blocks this one thread - it does not require spawning anything
  new during the hang itself, which is exactly what defeated the SSH
  watchdog's periodic fork()+exec() of a check script.
- The main thread wakes up periodically, checks how long ago the I/O
  thread last succeeded, and only pets /dev/watchdog if that's recent.
  Blocking syscalls release the GIL, so the main thread keeps running even
  while the I/O thread is stuck in D-state.
- If disk I/O stays stale for long enough, petting simply stops and the
  hardware watchdog resets the box on its own timeout - no process needs
  to be forked for that to happen.

Never closes /dev/watchdog deliberately; on many Pi kernels the driver is
built with nowayout, so once opened the watchdog can only be silenced by
a clean process exit that reopens (systemd Restart=always) or a reboot.
That's intentional: a gap in petting should be a controlled restart of
this daemon, not a way to disarm the watchdog.
"""

import logging
import os
import sys
import threading
import time

HEARTBEAT_FILE = "/var/lib/io-watchdog/heartbeat"
WATCHDOG_DEVICE = "/dev/watchdog"

IO_CHECK_INTERVAL_SEC = 5      # how often the I/O thread attempts a round-trip
PET_INTERVAL_SEC = 10          # how often the main thread considers petting
STALE_THRESHOLD_SEC = 30       # if last successful I/O is older than this, stop petting

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s io-watchdog: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("io-watchdog")

_lock = threading.Lock()
_last_success = time.monotonic()


def _record_success() -> None:
    global _last_success
    with _lock:
        _last_success = time.monotonic()


def _age_of_last_success() -> float:
    with _lock:
        return time.monotonic() - _last_success


def io_check_loop() -> None:
    os.makedirs(os.path.dirname(HEARTBEAT_FILE), exist_ok=True)
    while True:
        try:
            payload = f"{time.time()}\n".encode()
            fd = os.open(HEARTBEAT_FILE, os.O_WRONLY | os.O_CREAT | os.O_SYNC, 0o600)
            try:
                os.write(fd, payload)
                os.fsync(fd)
            finally:
                os.close(fd)
            with open(HEARTBEAT_FILE, "rb") as f:
                if f.read() != payload:
                    raise IOError("heartbeat readback mismatch")
            _record_success()
        except Exception as exc:  # noqa: BLE001 - must never let this thread die
            log.warning("disk I/O check failed: %s", exc)
        time.sleep(IO_CHECK_INTERVAL_SEC)


def pet_loop() -> None:
    try:
        wd = open(WATCHDOG_DEVICE, "wb", buffering=0)
    except OSError as exc:
        log.error("cannot open %s: %s - exiting so systemd can retry", WATCHDOG_DEVICE, exc)
        sys.exit(1)

    log.info("opened %s, starting pet loop (interval=%ss, stale-threshold=%ss)",
              WATCHDOG_DEVICE, PET_INTERVAL_SEC, STALE_THRESHOLD_SEC)

    while True:
        age = _age_of_last_success()
        if age < STALE_THRESHOLD_SEC:
            try:
                wd.write(b"\x00")
            except OSError as exc:
                log.error("failed to pet watchdog: %s", exc)
        else:
            log.error(
                "disk I/O stale (%.0fs, threshold=%ss) - NOT petting watchdog, "
                "hardware reset will follow if this persists",
                age, STALE_THRESHOLD_SEC,
            )
        time.sleep(PET_INTERVAL_SEC)


def main() -> None:
    log.info("starting io-watchdog")
    t = threading.Thread(target=io_check_loop, name="io-check", daemon=True)
    t.start()
    # Give the I/O thread one interval's head start before the main loop
    # starts deciding whether to pet, so a slow-but-healthy first check
    # doesn't look stale on startup.
    time.sleep(IO_CHECK_INTERVAL_SEC)
    pet_loop()


if __name__ == "__main__":
    main()
