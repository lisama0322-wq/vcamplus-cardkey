#!/usr/bin/env python3
"""Decrypt vcamplus encrypted debug.log — double-click to use"""
import base64, os, sys

KEY = bytes([0x56,0x43,0x4D,0x2B,0x6C,0x30,0x67,0x5F,0x6B,0x33,0x79,0x21])

def decrypt(b64_line):
    enc = base64.b64decode(b64_line.strip())
    return bytes(b ^ KEY[i % len(KEY)] for i, b in enumerate(enc)).decode('utf-8', errors='replace')

if __name__ == '__main__':
    script_dir = os.path.dirname(os.path.abspath(sys.argv[0]))
    log_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(script_dir, 'debug.log')

    if not os.path.exists(log_path):
        print(f'debug.log not found: {log_path}')
        print('Put debug.log in the same folder as this script, then double-click again.')
        input('Press Enter to exit...')
        sys.exit(1)

    out_path = os.path.join(os.path.dirname(log_path), 'debug_decoded.txt')
    count = 0
    with open(log_path, 'r') as f, open(out_path, 'w', encoding='utf-8') as out:
        for line in f:
            line = line.strip()
            if line:
                out.write(decrypt(line))
                count += 1

    print(f'Done! Decrypted {count} lines -> {out_path}')
    input('Press Enter to exit...')
