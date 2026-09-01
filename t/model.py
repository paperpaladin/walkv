#!/usr/bin/env python3
"""An outside opinion about what is in a walkv log.

Two halves, and neither of them asks walkv anything:

  parse()  reads the log with struct.unpack, from the format comment at the
           top of walkv.c, and returns a plain dict. It is a second
           implementation of the reader, so "the log says k4=v4" stops being
           walkv's reader agreeing with walkv's writer.

  model()  replays the operations the HARNESS ASKED FOR into another plain
           dict. Nothing walkv printed feeds it. That dict is the external
           notion of correctness the crash scenarios are checked against.

parse() is strict where walkv's reader is deliberately lenient. walkv stops at
the first short or corrupt record, because that is how a torn tail is made
safe. This refuses, because after recovery has run there must be no such tail
left: a lenient oracle would agree with a recovery that truncated nothing, and
truncating the tail is the thing being tested.
"""
import binascii
import struct
import sys

TOMB = 0xFFFFFFFF


def parse(path):
    """(live dict, record count), or ValueError naming the offset."""
    with open(path, "rb") as f:
        data = f.read()
    state, off, n = {}, 0, 0
    while off < len(data):
        if len(data) - off < 12:
            raise ValueError("short header at offset %d, %d bytes of %d left"
                             % (off, len(data) - off, len(data)))
        crc, klen, vlen = struct.unpack_from("<III", data, off)
        payload = 0 if vlen == TOMB else vlen
        end = off + 12 + klen + payload
        if end > len(data):
            raise ValueError("record at offset %d wants %d bytes, log has %d"
                             % (off, end - off, len(data) - off))
        if binascii.crc32(data[off + 4:end]) != crc:
            raise ValueError("bad crc at offset %d" % off)
        key = data[off + 12:off + 12 + klen]
        if vlen == TOMB:
            state.pop(key, None)
        else:
            state[key] = data[off + 12 + klen:end]
        off, n = end, n + 1
    return state, n


def model(path):
    """The state the workload asked for. `bulk N` is k0..k(N-1) = v0..v(N-1),
    which is the one piece of knowledge shared with the harness and with
    walkv's own `bulk`: the naming of the keys."""
    state = {}
    with open(path) as f:
        for line in f:
            op = line.split()
            if not op:
                continue
            if op[0] == "bulk":
                for i in range(int(op[1])):
                    state[b"k%d" % i] = b"v%d" % i
            elif op[0] == "put":
                state[op[1].encode()] = op[2].encode()
            elif op[0] == "del":
                state.pop(op[1].encode(), None)
            else:
                sys.exit("model.py: unknown operation %r" % line.strip())
    return state


def show(k):
    return k.decode("latin-1")


def main(argv):
    if len(argv) < 3:
        sys.exit("usage: model.py {check LOG OPS | dump LOG | records LOG}")
    cmd, log = argv[1], argv[2]
    try:
        state, n = parse(log)
    except ValueError as e:
        sys.exit("log is not clean: %s" % e)

    if cmd == "records":
        print(n)
    elif cmd == "dump":
        for k in sorted(state):
            print("%s=%s" % (show(k), show(state[k])))
    elif cmd == "check":
        want = model(argv[3])
        bad = []
        for k in sorted(want):
            if k not in state:
                bad.append("lost %s" % show(k))
            elif state[k] != want[k]:
                bad.append("%s is %s, should be %s"
                           % (show(k), show(state[k]), show(want[k])))
        for k in sorted(state):
            if k not in want:
                bad.append("invented %s=%s" % (show(k), show(state[k])))
        if bad:
            sys.exit("%d records, %d disagreements with the model: %s"
                     % (n, len(bad), "; ".join(bad[:6])))
        print("ok %d records" % n)
    else:
        sys.exit("model.py: unknown command %r" % cmd)


if __name__ == "__main__":
    main(sys.argv)
