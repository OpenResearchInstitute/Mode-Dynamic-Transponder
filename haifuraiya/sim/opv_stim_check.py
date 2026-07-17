#!/usr/bin/env python3
"""Confirm the easter-egg payload in a decoded bit stream from the testbench.
Usage: opv_stim_check.py rx_bits.txt  [--message "..."]
  rx_bits.txt : one decoded bit ('0'/'1') per line (or whitespace-separated),
                as dumped by the testbench after frame_sync locks.
Finds the 24-bit sync word 0x02B8DB, then decodes the following payload bytes
to ASCII and reports whether the easter-egg message is present."""
import sys, numpy as np
SYNC=0x02B8DB; SYNC_BITS=24; DEFAULT_MSG="HELLO WORLD FROM OPULENT VOICE - 73 DE W5NYV - "
def main():
    path=sys.argv[1]; msg=DEFAULT_MSG
    if "--message" in sys.argv: msg=sys.argv[sys.argv.index("--message")+1]
    raw=open(path).read().split()
    b=np.array([int(x) for x in raw if x in ("0","1")],dtype=np.uint8)
    syncbits=np.array([(SYNC>>(SYNC_BITS-1-i))&1 for i in range(SYNC_BITS)],dtype=np.uint8)
    # search both polarities (coherent demod may be inverted until sync resolves it)
    for inv,tag in ((0,"normal"),(1,"inverted")):
        bb = b^inv
        for i in range(len(bb)-SYNC_BITS-64):
            if np.array_equal(bb[i:i+SYNC_BITS],syncbits):
                pl=bb[i+SYNC_BITS:i+SYNC_BITS+8*len(msg)]
                by=bytes(int(''.join(map(str,pl[j:j+8])),2) for j in range(0,len(pl)//8*8,8))
                txt=by.decode('ascii','replace')
                ok = msg.strip()[:8] in txt
                print(f"[{tag}] sync @ bit {i}  ->  payload: {txt!r}   {'OK ✓' if ok else ''}")
                if ok: return 0
    print("sync word not found / message not present"); return 1
if __name__=="__main__": sys.exit(main())
