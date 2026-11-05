#!/usr/bin/env python3
"""Virtual Xbox 360 pad via uinput; loops a button/stick sequence until killed."""
import time
from evdev import UInput, AbsInfo, ecodes as e

caps = {
    e.EV_KEY: [e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST, e.BTN_TL, e.BTN_TR,
               e.BTN_SELECT, e.BTN_START, e.BTN_MODE, e.BTN_THUMBL, e.BTN_THUMBR],
    e.EV_ABS: [
        (e.ABS_X, AbsInfo(0, -32768, 32767, 16, 128, 0)),
        (e.ABS_Y, AbsInfo(0, -32768, 32767, 16, 128, 0)),
        (e.ABS_RX, AbsInfo(0, -32768, 32767, 16, 128, 0)),
        (e.ABS_RY, AbsInfo(0, -32768, 32767, 16, 128, 0)),
        (e.ABS_Z, AbsInfo(0, 0, 255, 0, 0, 0)),
        (e.ABS_RZ, AbsInfo(0, 0, 255, 0, 0, 0)),
        (e.ABS_HAT0X, AbsInfo(0, -1, 1, 0, 0, 0)),
        (e.ABS_HAT0Y, AbsInfo(0, -1, 1, 0, 0, 0)),
    ],
}
ui = UInput(caps, name="Microsoft X-Box 360 pad", vendor=0x045E, product=0x028E, version=0x0110)

def key(code, ms):
    ui.write(e.EV_KEY, code, 1); ui.syn(); time.sleep(ms / 1000)
    ui.write(e.EV_KEY, code, 0); ui.syn(); time.sleep(0.2)

def axes(pairs, ms):
    for c, v in pairs: ui.write(e.EV_ABS, c, v)
    ui.syn(); time.sleep(ms / 1000)
    for c, _ in pairs: ui.write(e.EV_ABS, c, 0)
    ui.syn(); time.sleep(0.2)

import sys
SAFE = "--safe" in sys.argv   # never press A/Start: safe to run against the real game at its main menu
try:
    time.sleep(3)  # let Steam pick the device up
    while True:
        if not SAFE: key(e.BTN_SOUTH, 200)
        key(e.BTN_EAST, 200)
        axes([(e.ABS_HAT0Y, -1)], 200)               # dpad up
        axes([(e.ABS_Y, 32767)], 500)                # left stick (0,+1) (down in evdev; Steam reports y=-1/+1 per its convention)
        axes([(e.ABS_RX, 32767), (e.ABS_RY, 32767)], 500)  # right stick
        time.sleep(1.0)
finally:
    ui.close()
