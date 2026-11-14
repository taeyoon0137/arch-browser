#!/usr/bin/env python3
# Finds Markdown that GitHub renders differently from what the text says: angle-bracket placeholders outside code,
# which GitHub drops as unknown HTML tags, pipes inside code spans in table rows, which split the cell, and paired
# tildes or dollar signs in prose, which become strikethrough or math. Pass --fix to escape the placeholders.
import re
import sys
from pathlib import Path

ALLOWED_TAGS = {"a", "b", "br", "code", "details", "div", "em", "h1", "i", "img", "kbd", "p", "picture", "pre",
                "source", "strong", "sub", "summary", "sup", "table", "td", "th", "tr"}
# Tags that show nothing without attributes, so a bare <source> or <img> in prose is a placeholder.
ATTRIBUTE_TAGS = {"img", "source"}
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
TAG = re.compile(r"(?<!\\)<(/?)([A-Za-z][\w -]*)[^<>]*>")


def outside_code(line):
    """Yields (start, end) ranges of the line that lie outside code spans."""
    position = 0
    for match in CODE_SPAN.finditer(line):
        yield position, match.start()
        position = match.end()
    yield position, len(line)


def is_placeholder(match):
    name = match.group(2).split()[0].lower()
    if name in ATTRIBUTE_TAGS:
        return re.fullmatch(r"</?\w+\s*/?>", match.group(0)) is not None
    return name not in ALLOWED_TAGS


def problems(line):
    found = []
    for start, end in outside_code(line):
        prose = re.sub(r"\]\([^)]*\)", "](…)", re.sub(r"<!--.*?-->", "", line[start:end]))
        found += [f"placeholder {m.group(0)} (GitHub drops it as an HTML tag)" for m in TAG.finditer(prose) if is_placeholder(m)]
        if len(re.findall(r"(?<!\\)~", prose)) >= 2:
            found.append("two tildes (strikethrough)")
        if len(re.findall(r"(?<!\\)\$", prose)) >= 2:
            found.append("two dollar signs (math)")
    if line.lstrip().startswith("|"):
        found += [f"pipe inside {m.group(0)} in a table cell" for m in CODE_SPAN.finditer(line)
                  if re.search(r"(?<!\\)\|", m.group(2))]
    return found


def escaped(line):
    """Escapes placeholders outside code spans as \\<name>."""
    pieces, position = [], 0
    for start, end in outside_code(line):
        pieces.append(line[position:start])
        pieces.append(TAG.sub(lambda m: "\\" + m.group(0) if is_placeholder(m) else m.group(0), line[start:end]))
        position = end
    pieces.append(line[position:])
    return "".join(pieces)


def check(path, fix):
    lines = path.read_text(encoding="utf-8").split("\n")
    in_fence, count = False, 0
    for index, line in enumerate(lines):
        if re.match(r"\s*(```|~~~)", line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if fix and any(p.startswith("placeholder") for p in problems(line)):
            lines[index] = line = escaped(line)
        for problem in problems(line):
            print(f"{path}:{index + 1}: {problem}")
            count += 1
    if fix:
        path.write_text("\n".join(lines), encoding="utf-8")
    return count


def main():
    arguments = [a for a in sys.argv[1:] if a != "--fix"]
    fix = "--fix" in sys.argv[1:]
    paths = [Path(a) for a in arguments] or [Path("README.md"), Path("AGENTS.md"), Path("resources/README.preset.md"),
                                              *sorted(Path("docs").glob("*.md"))]
    total = sum(check(p, fix) for p in paths)
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
