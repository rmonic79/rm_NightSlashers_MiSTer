#!/usr/bin/env python3
"""
Genera file .mem con encoding tier+ASCII per modulo pause_text.

Formato output: 1 word 9-bit per char (2 bit tier + 7 bit ASCII), salvato
come 16-bit hex (1 word per riga, valore <= 0x1FF).

Sintassi sorgente .txt:
  - Righe che iniziano con `@` sono separatori/commenti — IGNORATE.
  - Righe che iniziano con `N:` (N=0..3) → tier=N, testo dopo i due punti.
  - Righe normali → tier=0 (default, bianco).
  - Righe vuote → riga vuota tier=0.

Char accettati: 0x20-0x5F (uppercase). Lowercase a..z viene convertito in A..Z.
Char fuori range diventano space (0x20).

Usage:
  python gen_msg.py file.txt file.mem CHAR_PER_ROW NUM_ROWS
"""

import sys
import os


def normalize_char(c):
    code = ord(c) if isinstance(c, str) else c
    if 0x61 <= code <= 0x7A:
        code -= 0x20
    if 0x20 <= code <= 0x5F:
        return code
    return 0x20


def parse_line(line):
    """Ritorna (tier, text) — tier 0..3, text già normalizzato."""
    if line.startswith("@"):
        return None  # commento, skip
    tier = 0
    if len(line) >= 2 and line[0] in "0123" and line[1] == ":":
        tier = int(line[0])
        line = line[2:]
    return (tier, line)


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)
    in_path = sys.argv[1]
    out_path = sys.argv[2]
    chars_per_row = int(sys.argv[3])
    num_rows = int(sys.argv[4])

    with open(in_path, "r", encoding="utf-8") as f:
        raw_lines = [l.rstrip("\n") for l in f.readlines()]

    parsed = []
    for raw in raw_lines:
        result = parse_line(raw)
        if result is None:
            continue
        parsed.append(result)

    # Trunca o pad righe
    if len(parsed) < num_rows:
        parsed += [(0, "")] * (num_rows - len(parsed))
    else:
        parsed = parsed[:num_rows]

    words_out = []
    for tier, line in parsed:
        if len(line) < chars_per_row:
            line = line.ljust(chars_per_row)
        else:
            line = line[:chars_per_row]
        for c in line:
            ascii_code = normalize_char(c)
            word = (tier << 7) | (ascii_code & 0x7F)
            words_out.append(word)

    expected = chars_per_row * num_rows
    assert len(words_out) == expected, f"size mismatch: {len(words_out)} != {expected}"

    with open(out_path, "w") as f:
        for w in words_out:
            f.write(f"{w:03X}\n")

    print(f"Saved {out_path} ({len(words_out)} words = {chars_per_row}x{num_rows})")


if __name__ == "__main__":
    main()
