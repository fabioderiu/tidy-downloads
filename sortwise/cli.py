"""Command-line interface for sortwise."""

import argparse
import sys
from pathlib import Path

from . import __version__
from .core import (
    tidy_all,
    tidy_directory,
    format_plan,
    save_api_key,
    get_enabled_dirs,
    set_dir_enabled,
    SUPPORTED_DIRS,
)


def main():
    parser = argparse.ArgumentParser(
        prog="sortwise",
        description="AI-powered folder organizer. Uses Claude to classify files into smart categories.",
    )
    parser.add_argument("--move", action="store_true", help="Actually move files (default is dry-run)")
    parser.add_argument("--no-ai", action="store_true", help="Use extension-based sorting instead of AI")
    parser.add_argument("--age-days", type=int, default=30, help="Move files older than N days to _old/ (default: 30)")
    parser.add_argument("--dir", type=str, help="Organize a specific directory (Downloads, Documents, or Desktop)")
    parser.add_argument("--enable", type=str, metavar="DIR", help="Enable a directory for auto-tidy")
    parser.add_argument("--disable", type=str, metavar="DIR", help="Disable a directory from auto-tidy")
    parser.add_argument("--setup-key", action="store_true", help="Save your Anthropic API key")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = parser.parse_args()

    if args.setup_key:
        key = input("Paste your Anthropic API key: ").strip()
        if not key:
            print("No key provided.", file=sys.stderr)
            sys.exit(1)
        save_api_key(key)
        print("API key saved.")
        return

    if args.enable:
        if args.enable not in SUPPORTED_DIRS:
            print(f"  Unknown directory: {args.enable}. Choose from: {', '.join(SUPPORTED_DIRS)}", file=sys.stderr)
            sys.exit(1)
        set_dir_enabled(args.enable, True)
        print(f"  ✅ {args.enable} enabled for auto-tidy.")
        return

    if args.disable:
        if args.disable not in SUPPORTED_DIRS:
            print(f"  Unknown directory: {args.disable}. Choose from: {', '.join(SUPPORTED_DIRS)}", file=sys.stderr)
            sys.exit(1)
        set_dir_enabled(args.disable, False)
        print(f"  ✅ {args.disable} disabled for auto-tidy.")
        return

    use_ai = not args.no_ai
    print(f"\n  🧹 sortwise v{__version__}\n")

    # Single directory mode
    if args.dir:
        target = Path.home() / args.dir
        if not target.exists():
            print(f"  ~/{args.dir} does not exist.", file=sys.stderr)
            sys.exit(1)
        found, moves, moved = tidy_directory(target, use_ai=use_ai, age_days=args.age_days, dry_run=not args.move)
        if not found:
            print(f"  ~/{args.dir} is empty!")
            return
        prefix = "[DRY RUN] " if not args.move else ""
        print(f"  ~/{args.dir}: {found} items")
        print(f"  {prefix}{format_plan(moves, target)}")
        if moves and not args.move:
            print(f"\n  Run with --move to execute.\n")
        elif moved:
            print(f"\n  ✅ Moved {moved} files.\n")
        return

    # All enabled directories
    enabled = get_enabled_dirs()
    if not enabled:
        print("  No directories enabled. Use --enable Downloads/Documents/Desktop")
        return

    method = "AI" if use_ai else "extension-based"
    print(f"  Classifying with {method} sorting...")
    print(f"  Watching: {', '.join('~/' + d.name for d in enabled)}\n")

    try:
        results = tidy_all(use_ai=use_ai, age_days=args.age_days, dry_run=not args.move)
    except RuntimeError as e:
        print(f"  {e}", file=sys.stderr)
        sys.exit(1)

    prefix = "[DRY RUN] " if not args.move else ""
    total_moved = 0
    for dir_name, (found, moves, moved) in results.items():
        target = Path.home() / dir_name
        print(f"  📂 ~/{dir_name} ({found} items)")
        if moves:
            print(f"  {prefix}{format_plan(moves, target)}\n")
        else:
            print(f"  Already tidy!\n")
        total_moved += moved

    if any(m for _, m, _ in results.values()) and not args.move:
        print(f"  Run with --move to execute.\n")
    elif total_moved:
        print(f"  ✅ Moved {total_moved} files total.\n")


if __name__ == "__main__":
    main()
