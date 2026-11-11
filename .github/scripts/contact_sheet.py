#!/usr/bin/env python3
"""Stitch the two runs of HermesOpenReadShotsTests into one contact sheet.

Each run shoots two frames of the same chat open — one while the socket is parked at
`session.resume`, one once it connects — and writes `notes.json` beside them saying what
it saw. The sheet puts the base tree over this pull request, the two moments side by side,
and prints each frame's numbers under it.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

MARGIN = 44
GUTTER = 36
FRAME_WIDTH = 380
TITLE_SIZE = 32
SUBTITLE_SIZE = 16
ROW_LABEL_SIZE = 20
COLUMN_LABEL_SIZE = 15
CAPTION_SIZE = 14
FOOTNOTE_SIZE = 14
LINE_SPACING = 6

FONT_REGULAR = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]
FONT_BOLD = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]

INK = (24, 24, 27)
MUTED = (96, 96, 108)
RULE = (223, 223, 229)
PAPER = (255, 255, 255)
PANEL = (246, 246, 249)

_FONTS: dict[tuple[int, bool], ImageFont.ImageFont | ImageFont.FreeTypeFont] = {}


def font(size: int, bold: bool = False) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    key = (size, bold)
    if key in _FONTS:
        return _FONTS[key]
    for path in FONT_BOLD if bold else FONT_REGULAR:
        if pathlib.Path(path).exists():
            try:
                _FONTS[key] = ImageFont.truetype(path, size)
                return _FONTS[key]
            except OSError:
                continue
    _FONTS[key] = ImageFont.load_default(size=size)
    return _FONTS[key]


_MEASURE = ImageDraw.Draw(Image.new("RGB", (8, 8)))


def wrap(text: str, size: int, width: int, bold: bool = False) -> list[str]:
    """Greedy word wrap, measured, so nothing runs past its column or off the sheet."""
    face = font(size, bold=bold)
    lines: list[str] = []
    for paragraph in text.split("\n"):
        current = ""
        for word in paragraph.split(" "):
            candidate = word if not current else f"{current} {word}"
            if _MEASURE.textlength(candidate, font=face) <= width or not current:
                current = candidate
            else:
                lines.append(current)
                current = word
        lines.append(current)
    return lines


def block(text: str, size: int, width: int, bold: bool = False) -> tuple[list[str], int]:
    lines = wrap(text, size, width, bold=bold)
    return lines, len(lines) * (size + LINE_SPACING)


def load_notes(directory: pathlib.Path) -> dict:
    path = directory / "notes.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def load_frame(directory: pathlib.Path, name: str, caption: str) -> Image.Image:
    path = directory / f"{name}.png"
    if path.exists():
        try:
            frame = Image.open(path).convert("RGB")
            height = round(frame.height * FRAME_WIDTH / frame.width)
            return frame.resize((FRAME_WIDTH, height), Image.LANCZOS)
        except OSError:
            pass
    # A missing frame still gets a cell: the sheet has to show the gap, not hide it.
    placeholder = Image.new("RGB", (FRAME_WIDTH, 484), PANEL)
    draw = ImageDraw.Draw(placeholder)
    draw.rectangle([1, 1, FRAME_WIDTH - 2, 483], outline=RULE)
    draw.text((22, 22), "no frame was shot", font=font(15, bold=True), fill=INK)
    for index, line in enumerate(wrap(f"{caption} — the run's log says why", 13, FRAME_WIDTH - 44)):
        draw.text((22, 52 + index * 18), line, font=font(13), fill=MUTED)
    return placeholder


def caption_for(notes: dict, moment: str) -> str:
    if not notes:
        return "no notes.json from this run"
    entry = notes.get("open" if moment == "open" else "connected") or {}
    rows = entry.get("rows", 0)
    seconds = entry.get("seconds", 0.0)
    connected = entry.get("connected", False)
    reads = len(entry.get("offsets", []))
    state = "socket connected" if connected else "socket still recovering"
    reads_label = "read" if reads == 1 else "reads"
    if moment == "open":
        return f"{rows} rows at t+{seconds:.2f}s · {state} · {reads} transcript {reads_label}"
    return f"{rows} rows · {state} · {reads} transcript {reads_label}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--before-label", default="before")
    parser.add_argument("--after-label", default="after")
    args = parser.parse_args()

    runs = [
        ("Before · the open waits for the handshake", args.before_label, pathlib.Path(args.before)),
        ("After · the transcript is read beside the attach", args.after_label, pathlib.Path(args.after)),
    ]
    moments = [("the open · handshake parked", "open"), ("connected", "connected")]

    width = MARGIN * 2 + FRAME_WIDTH * 2 + GUTTER
    column_width = FRAME_WIDTH

    title = "Hermex · opening a chat"
    subtitle = (
        "Frames shot by HermesMobileTests on GitHub's xcode-27 runner, iPhone 17 · iOS 27. The socket is "
        "parked at session.resume, so the handshake never finishes and the open is the only thing running."
    )
    footnote = (
        "Before the fix the transcript read is sent by the rebuild, after the handshake: while the socket "
        "recovers the chat has no rows. After it the read goes out from activate(), beside the attach, so the "
        "rows are up in the read's time and the rebuild joins that read instead of sending another."
    )
    subtitle_lines, subtitle_height = block(subtitle, SUBTITLE_SIZE, width - 2 * MARGIN)
    footnote_lines, footnote_height = block(footnote, FOOTNOTE_SIZE, width - 2 * MARGIN)

    # Each run renders twice: label, column headers, the taller frame, its captions.
    cells = []
    for row_label, tree_label, directory in runs:
        notes = load_notes(directory)
        shots = []
        for column_label, moment in moments:
            frame = load_frame(directory, "01-open" if moment == "open" else "02-connected",
                               caption_for(notes, moment))
            caption = caption_for(notes, moment)
            caption_lines, caption_height = block(caption, CAPTION_SIZE, column_width)
            shots.append((column_label, frame, caption_lines, caption_height))
        cells.append((row_label, tree_label, shots))

    title_block = TITLE_SIZE + 14 + subtitle_height + 24
    heights = [
        ROW_LABEL_SIZE + 14 + COLUMN_LABEL_SIZE + 10 + max(shot[1].height for shot in shots) + 12
        + max(shot[3] for shot in shots) + 30
        for _, _, shots in cells
    ]
    height = MARGIN + title_block + sum(heights) + footnote_height + MARGIN

    sheet = Image.new("RGB", (width, height), PAPER)
    draw = ImageDraw.Draw(sheet)

    draw.text((MARGIN, MARGIN), title, font=font(TITLE_SIZE, bold=True), fill=INK)
    y = MARGIN + TITLE_SIZE + 14
    for line in subtitle_lines:
        draw.text((MARGIN, y), line, font=font(SUBTITLE_SIZE), fill=MUTED)
        y += SUBTITLE_SIZE + LINE_SPACING
    y += 24 - LINE_SPACING
    draw.line([(MARGIN, y), (width - MARGIN, y)], fill=RULE, width=1)
    y += 22

    for (row_label, tree_label, shots), row_height in zip(cells, heights):
        del row_height
        draw.text((MARGIN, y), row_label, font=font(ROW_LABEL_SIZE, bold=True), fill=INK)
        tree_width = _MEASURE.textlength(tree_label, font=font(13))
        draw.text((width - MARGIN - tree_width, y + 5), tree_label, font=font(13), fill=MUTED)
        y += ROW_LABEL_SIZE + 14
        for column, (column_label, _, _, _) in enumerate(shots):
            draw.text((MARGIN + column * (column_width + GUTTER), y), column_label.upper(),
                      font=font(COLUMN_LABEL_SIZE, bold=True), fill=MUTED)
        y += COLUMN_LABEL_SIZE + 10
        tallest = max(shot[1].height for shot in shots)
        for column, (_, frame, _, _) in enumerate(shots):
            x = MARGIN + column * (column_width + GUTTER)
            sheet.paste(frame, (x, y))
            draw.rectangle([x, y, x + frame.width - 1, y + frame.height - 1], outline=RULE)
        y += tallest + 12
        for column, (_, _, caption_lines, _) in enumerate(shots):
            x = MARGIN + column * (column_width + GUTTER)
            line_y = y
            for line in caption_lines:
                draw.text((x, line_y), line, font=font(CAPTION_SIZE), fill=MUTED)
                line_y += CAPTION_SIZE + LINE_SPACING
        y += max(shot[3] for shot in shots) + 30

    draw.line([(MARGIN, y - 14), (width - MARGIN, y - 14)], fill=RULE, width=1)
    y += 8
    for line in footnote_lines:
        draw.text((MARGIN, y), line, font=font(FOOTNOTE_SIZE), fill=MUTED)
        y += FOOTNOTE_SIZE + LINE_SPACING

    sheet.save(args.out, "PNG")
    print(f"wrote {args.out} ({sheet.width}x{sheet.height})")
    for row_label, tree_label, shots in cells:
        for column_label, _, _, _ in shots:
            print(f"  {row_label[:26]:26} {column_label[:24]:24} {tree_label}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
