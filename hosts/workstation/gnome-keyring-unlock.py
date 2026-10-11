# Unlocks the login keyring of the running gnome-keyring-daemon, the same way
# pam_gnome_keyring does after a password login: GKD_CONTROL_OP_UNLOCK on the
# control socket (protocol: daemon/control/gkd-control-client.c upstream).
# The password comes from the file in argv[1]. The exit status is the daemon's
# GKD_CONTROL_RESULT_*: 0 ok, 1 denied, 2 failed.
import os
import socket
import struct
import sys

OP_UNLOCK = 1

with open(sys.argv[1], "rb") as f:
    password = f.read().rstrip(b"\n")

body = struct.pack(">II", OP_UNLOCK, len(password)) + password
path = os.path.join(os.environ["XDG_RUNTIME_DIR"], "keyring", "control")

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.connect(path)
    # The daemon reads one byte first, then checks the peer UID.
    sock.sendall(b"\0" + struct.pack(">I", 4 + len(body)) + body)
    _, result = struct.unpack(">II", sock.makefile("rb").read(8))

sys.exit(result)
