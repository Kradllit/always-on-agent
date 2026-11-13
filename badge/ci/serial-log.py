# Log the badge's serial console to a file, with a time on every line.
#   source ci/idf-env.sh && python ci/serial-log.py [--reset] [port] > logs/serial.log
# pyserial comes with ESP-IDF's Python (the one tool here that isn't Bun: Bun has no serial).
import sys, time, glob, serial

args = [a for a in sys.argv[1:] if a != "--reset"]
port = args[0] if args else sorted(glob.glob("/dev/cu.usbmodem*"))[0]
s = serial.Serial()
s.port, s.baudrate, s.timeout = port, 115200, 0.2


def open_quietly():
    # Opening the port must not restart the badge (it would hide why a sleeping badge woke).
    # macOS raises both control lines on open, and the chip restarts if RTS is still up when
    # DTR drops, which is the order pyserial drops them in. So: RTS down first, then DTR.
    s.dtr, s.rts = True, False
    s.open()
    s.dtr = False


open_quietly()
if "--reset" in sys.argv:  # restart the badge so the log starts at boot
    s.rts = True
    time.sleep(0.15)
    s.rts = False
buf = b""
while True:
    try:
        buf += s.read(4096)
    except serial.SerialException:  # the badge restarted or was unplugged: wait for it
        time.sleep(0.5)
        try:
            s.close(); open_quietly()
        except Exception:
            pass
        continue
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        print(time.strftime("%H:%M:%S"), line.decode("utf-8", "replace").rstrip("\r"), flush=True)
