#!/usr/bin/env python3
"""
report.py - Parse nextpnr JSON report and display utilization/timing
"""

import json
import sys

def main():
    if len(sys.argv) < 2:
        print("Usage: report.py <report.rpt> [bitstream.bin]")
        sys.exit(1)
    
    rpt_file = sys.argv[1]
    bin_file = sys.argv[2] if len(sys.argv) > 2 else None
    
    with open(rpt_file) as f:
        r = json.load(f)
    
    # Resource utilization
    u = r.get('utilization', {})
    print('  RESOURCE UTILIZATION')
    print('  ' + '─'*50)
    for k, v in u.items():
        if 'used' in v and 'available' in v:
            pct = 100 * v['used'] / v['available']
            bar = '█' * int(pct/5) + '░' * (20 - int(pct/5))
            print(f"  {k:15} {v['used']:6} / {v['available']:<6} {bar} {pct:5.1f}%")
    print()
    
    # Timing
    fmax = r.get('fmax', {})
    if fmax:
        print('  TIMING')
        print('  ' + '─'*50)
        for clk, data in fmax.items():
            # Handle nested dict structure: {achieved: X, constraint: Y}
            if isinstance(data, dict):
                freq = data.get('achieved', 0)
                constraint = data.get('constraint', 12)
            else:
                freq = data
                constraint = 12
            
            status = '✓ PASS' if freq > constraint else '✗ FAIL'
            # Clean up clock name (remove $SB_IO_IN_$glb_clk suffix)
            clk_name = clk.split('$')[0] if '$' in clk else clk
            print(f"  {clk_name}: {freq:.2f} MHz (need {constraint} MHz) {status}")
        print()
    
    # Bitstream info
    if bin_file:
        import os
        if os.path.exists(bin_file):
            size = os.path.getsize(bin_file)
            if size > 1024:
                size_str = f"{size/1024:.0f}K"
            else:
                size_str = f"{size}B"
            print('  BITSTREAM')
            print('  ' + '─'*50)
            print(f"  Size: {size_str}  File: {bin_file}")
            print()

if __name__ == '__main__':
    main()
