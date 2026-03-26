import re
import sys

try:
    from pypinyin import lazy_pinyin
except ImportError:
    sys.exit(2)


def to_slug(text: str) -> str:
    parts = []
    for token in lazy_pinyin(text, errors="default"):
        normalized = re.sub(r"[^A-Za-z0-9]+", "-", token.lower()).strip("-")
        if normalized:
            parts.append(normalized)

    slug = re.sub(r"-{2,}", "-", "-".join(parts)).strip("-")
    return slug[:100].strip("-")


def main() -> int:
    if len(sys.argv) < 2:
        return 1

    slug = to_slug(sys.argv[1])
    if not slug:
        return 1

    print(slug)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
