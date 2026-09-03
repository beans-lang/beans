#!/usr/bin/env python3
"""Regenerate the display-width tables inside runtime/beans_rt.c.

The tables answer one question: how many terminal columns does a Unicode
scalar occupy. They are derived from the Unicode Character Database, never
typed by hand, so a new Unicode release is a re-run of this script rather
than an edit.

    tools/gen_width_table.py                    # download the latest UCD
    tools/gen_width_table.py --ucd DIR          # use files already on disk
    tools/gen_width_table.py --check            # fail if the tree is stale

Four UCD files feed it:

    EastAsianWidth.txt          W and F are the two-column scalars
    extracted/DerivedGeneralCategory.txt
                                Mn, Me and Cf are the zero-width marks;
                                Cc are the controls
    emoji/emoji-data.txt        Emoji_Presentation (two columns by default),
                                Emoji_Modifier (skin tones, zero), and
                                Extended_Pictographic (what a variation
                                selector may promote or demote)
    auxiliary/GraphemeBreakProperty.txt
                                Hangul jamo V and T combine onto the
                                preceding L and take no column of their own

The generated block is bracketed by the two markers below; everything
between them is replaced. Nothing outside them is touched.
"""

import argparse
import os
import re
import sys
import urllib.request

BEGIN = "/* BEGIN GENERATED display-width tables"
END = "/* END GENERATED display-width tables */"

UCD_BASE = "https://www.unicode.org/Public/UCD/latest/ucd/"
FILES = {
    "EastAsianWidth.txt": "EastAsianWidth.txt",
    "DerivedGeneralCategory.txt": "extracted/DerivedGeneralCategory.txt",
    "emoji-data.txt": "emoji/emoji-data.txt",
    "GraphemeBreakProperty.txt": "auxiliary/GraphemeBreakProperty.txt",
}

# U+00AD SOFT HYPHEN is Cf, but every terminal draws it as a hyphen and both
# wcwidth and the unicode-width crate call it one column. It is the single
# scalar this table overrides its own source data for.
SOFT_HYPHEN = 0x00AD


def read_ucd(name, ucd_dir):
    if ucd_dir:
        path = os.path.join(ucd_dir, name)
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    url = UCD_BASE + FILES[name]
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read().decode("utf-8")


def unicode_version(text):
    first = text.splitlines()[0]
    match = re.search(r"-(\d+\.\d+\.\d+)\.txt", first)
    return match.group(1) if match else "unknown"


def parse(text, wanted):
    """Every code point whose second field is one of `wanted`."""
    found = set()
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [piece.strip() for piece in line.split(";")]
        if len(parts) < 2 or parts[1] not in wanted:
            continue
        span = parts[0]
        if ".." in span:
            low, high = span.split("..")
        else:
            low = high = span
        for point in range(int(low, 16), int(high, 16) + 1):
            found.add(point)
    return found


def eaw_defaults():
    """Unassigned code points that EastAsianWidth.txt gives W by default.

    The file lists them in its header rather than in its rows; a table built
    only from the rows would call an unassigned CJK ideograph one column.
    """
    found = set()
    for low, high in (
        (0x3400, 0x4DBF),
        (0x4E00, 0x9FFF),
        (0xF900, 0xFAFF),
        (0x20000, 0x2FFFD),
        (0x30000, 0x3FFFD),
    ):
        found.update(range(low, high + 1))
    return found


def ranges(points):
    """A sorted set of code points as a list of inclusive [lo, hi] runs."""
    out = []
    for point in sorted(points):
        if out and point == out[-1][1] + 1:
            out[-1][1] = point
        else:
            out.append([point, point])
    return out


def render(name, runs):
    lines = [
        "static const unsigned int %s[][2] = {" % name,
    ]
    row = "   "
    for low, high in runs:
        piece = " {0x%X,0x%X}," % (low, high)
        if len(row) + len(piece) > 78:
            lines.append(row)
            row = "   "
        row += piece
    if row.strip():
        lines.append(row)
    lines.append("};")
    return "\n".join(lines)


def build(ucd_dir):
    eaw_text = read_ucd("EastAsianWidth.txt", ucd_dir)
    gc_text = read_ucd("DerivedGeneralCategory.txt", ucd_dir)
    emoji_text = read_ucd("emoji-data.txt", ucd_dir)
    gcb_text = read_ucd("GraphemeBreakProperty.txt", ucd_dir)

    version = unicode_version(eaw_text)

    wide = parse(eaw_text, {"W", "F"}) | eaw_defaults()
    marks = parse(gc_text, {"Mn", "Me", "Cf"})
    controls = parse(gc_text, {"Cc"})
    presentation = parse(emoji_text, {"Emoji_Presentation"})
    modifiers = parse(emoji_text, {"Emoji_Modifier"})
    pictographic = parse(emoji_text, {"Extended_Pictographic"})
    jamo = parse(gcb_text, {"V", "T"})

    zero = marks | controls | modifiers | jamo
    zero.discard(SOFT_HYPHEN)

    wide = (wide | presentation) - zero

    # A scalar a variation selector can move: pictographic and not already
    # settled at zero. VS16 pushes a one-column one to two, VS15 pulls a
    # two-column one back to one.
    pictographic = pictographic - zero

    return version, ranges(zero), ranges(wide), ranges(pictographic)


def generated(version, zero, wide, pictographic):
    header = (
        "%s — Unicode %s.\n"
        "   Regenerate with tools/gen_width_table.py; do not edit by hand.\n"
        "   zero: Mn/Me/Cf marks, Cc controls, Hangul jamo V/T, and the emoji\n"
        "   skin-tone modifiers, less U+00AD which terminals draw.\n"
        "   wide: East_Asian_Width W and F, plus Emoji_Presentation.\n"
        "   pict: Extended_Pictographic, which a variation selector moves. */"
        % (BEGIN, version)
    )
    return "\n".join(
        [
            header,
            render("width_zero_ranges", zero),
            render("width_wide_ranges", wide),
            render("width_pict_ranges", pictographic),
            END,
        ]
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ucd", help="directory holding the UCD text files")
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero when the tree's tables differ from the data",
    )
    parser.add_argument(
        "--out",
        default=os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "runtime",
            "beans_rt.c",
        ),
    )
    args = parser.parse_args()

    version, zero, wide, pictographic = build(args.ucd)
    block = generated(version, zero, wide, pictographic)

    with open(args.out, "r", encoding="utf-8") as handle:
        source = handle.read()
    start = source.find(BEGIN)
    stop = source.find(END)
    if start < 0 or stop < 0:
        sys.stderr.write("%s: the generated width block is missing\n" % args.out)
        return 2
    stop += len(END)
    updated = source[:start] + block + source[stop:]

    if args.check:
        if updated != source:
            sys.stderr.write(
                "%s: the display-width tables are stale; run "
                "tools/gen_width_table.py\n" % args.out
            )
            return 1
        sys.stdout.write("width tables current (Unicode %s)\n" % version)
        return 0

    if updated != source:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(updated)
    sys.stdout.write(
        "width tables from Unicode %s: %d zero ranges, %d wide ranges, "
        "%d pictographic ranges\n" % (version, len(zero), len(wide), len(pictographic))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
