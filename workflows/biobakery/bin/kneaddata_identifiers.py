#!/usr/bin/env python3
"""kneaddata_identifiers.py - FASTQ read identifiers in the form KneadData wants.

Author: Daniel Smith
Date:   October 14th, 2026

Copies FASTQ from standard input to standard output, rewriting each identifier
as KneadData 0.12.4 does before it starts (get_reformatted_identifiers in
kneaddata/utilities.py). An identifier with a space, or not ending in /1 or /2,
becomes its first word with #0/1 or #0/2 appended, and its + line is left bare.
Any other passes through unchanged.

KneadData skips its own rewrite, which writes the whole sample out again, when
it finds every identifier already in this form.

Usage:     kneaddata_identifiers.py <mate> < reads.fastq > reformatted.fastq
Called by: KNEADDATA, in modules/kneaddata.nf
Requires:  Python 3 alone, in the KneadData container
Outputs:   the reads on standard output
"""

import sys


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("1", "2"):
        print("Usage: kneaddata_identifiers.py <1|2> < reads.fastq > reformatted.fastq", file=sys.stderr)
        return 2

    suffix = "#0/" + sys.argv[1] + "\n"
    lines = iter(sys.stdin)

    for header in lines:
        try:
            seq, plus, qual = next(lines), next(lines), next(lines)
        except StopIteration:
            print(f"kneaddata_identifiers.py: truncated record at {header.rstrip()}", file=sys.stderr)
            return 1

        if " " in header or not header.endswith(("/1\n", "/2\n")):
            header = header.split(" ")[0].rstrip() + suffix
            plus = "+\n"

        sys.stdout.write(header + seq + plus + qual)

    return 0


if __name__ == "__main__":
    sys.exit(main())
