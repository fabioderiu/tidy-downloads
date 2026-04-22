"""Core logic: scanning, classification, and file organization."""

import json
import os
import shutil
import time
import urllib.request
import urllib.error
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "sortwise"
CONFIG_FILE = CONFIG_DIR / "config.json"
LOG_FILE = CONFIG_DIR / "last-run.json"

SUPPORTED_DIRS = ["Downloads", "Documents", "Desktop"]
DEFAULT_ENABLED = {"Downloads"}

MANAGED_FOLDERS = {"_old"}

EXT_MAP = {
    "documents": {"pdf", "doc", "docx", "txt", "rtf", "odt", "pages", "md", "csv", "xls", "xlsx"},
    "images": {"jpg", "jpeg", "png", "gif", "webp", "svg", "heic", "tiff", "bmp", "ico"},
    "archives": {"zip", "tar", "gz", "bz2", "rar", "7z", "dmg", "iso"},
    "videos": {"mp4", "mov", "avi", "mkv", "webm", "m4v"},
    "audio": {"mp3", "wav", "aac", "flac", "ogg", "m4a"},
    "code": {"json", "py", "js", "ts", "html", "css", "sql", "sh", "go", "yaml", "yml", "xml"},
    "design": {"psd", "ai", "sketch", "fig", "xd"},
    "installers": {"pkg", "app", "exe", "msi"},
}


def load_config():
    """Load configuration from disk."""
    if CONFIG_FILE.exists():
        return json.loads(CONFIG_FILE.read_text())
    return {}


def save_config(cfg):
    """Write configuration to disk."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))
    CONFIG_FILE.chmod(0o600)


def get_api_key():
    """Get API key from env var or config file."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    return load_config().get("api_key")


def save_api_key(key):
    """Save API key to config file."""
    cfg = load_config()
    cfg["api_key"] = key
    save_config(cfg)


def get_enabled_dirs():
    """Return list of enabled directory Paths."""
    cfg = load_config()
    enabled = cfg.get("watched_dirs", {})
    if not enabled:
        # Legacy/first-run: only Downloads
        return [Path.home() / "Downloads"]
    return [Path.home() / name for name, on in enabled.items() if on]


def set_dir_enabled(dir_name, enabled):
    """Toggle a watched directory on or off."""
    cfg = load_config()
    watched = cfg.get("watched_dirs", {d: d == "Downloads" for d in SUPPORTED_DIRS})
    watched[dir_name] = enabled
    cfg["watched_dirs"] = watched
    save_config(cfg)


def get_managed_folders(target_dir):
    """Return set of folder names to skip: _old + previously created categories for this dir."""
    skip = set(MANAGED_FOLDERS)
    cfg = load_config()
    dir_name = target_dir.name
    by_dir = cfg.get("category_folders_by_dir", {})
    skip.update(by_dir.get(dir_name, []))
    # Legacy support
    if dir_name == "Downloads":
        skip.update(cfg.get("category_folders", []))
    return skip


def scan_directory(target_dir):
    """Return list of top-level items in a directory, skipping managed folders."""
    skip = get_managed_folders(target_dir)
    items = []
    if not target_dir.exists():
        return items
    for entry in target_dir.iterdir():
        if entry.name.startswith("."):
            continue
        if entry.name in skip:
            continue
        stat = entry.stat()
        age_days = (time.time() - stat.st_mtime) / 86400
        items.append({
            "name": entry.name,
            "is_dir": entry.is_dir(),
            "size_bytes": stat.st_size if not entry.is_dir() else 0,
            "age_days": round(age_days, 1),
            "ext": entry.suffix.lstrip(".").lower() if entry.suffix else "",
        })
    return items


# Keep backward-compatible alias
def scan_downloads(downloads_dir=None):
    return scan_directory(downloads_dir or Path.home() / "Downloads")


def classify_by_extension(items):
    """Fallback: classify items by file extension."""
    result = {}
    for item in items:
        ext = item["ext"]
        category = "other"
        for cat, exts in EXT_MAP.items():
            if ext in exts:
                category = cat
                break
        result[item["name"]] = category
    return result


def classify_with_ai(items, api_key, dir_name="Downloads"):
    """Send filenames to Claude Haiku for smart classification."""
    file_list = "\n".join(
        f"- {item['name']} ({'folder' if item['is_dir'] else item['ext'] or 'no-ext'}, "
        f"{item['age_days']}d old)"
        for item in items
    )

    prompt = f"""Classify these files from a user's ~/{dir_name} folder into intuitive categories.

Rules:
- Return ONLY valid JSON: {{"filename": "category", ...}}
- Use short, lowercase category names (e.g., "receipts", "travel", "work", "photos", "archives", "design", "personal", "code", "installers", "videos", "other")
- Group related files together (e.g., flight tickets + boarding passes = "travel")
- Infer purpose from filenames — "transaction", "invoice", "receipt" → "receipts"
- Be practical: a user should know where to find things
- Every file in the list must appear in your response

Files:
{file_list}"""

    body = json.dumps({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 2048,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-API-Key": api_key,
            "Anthropic-Version": "2023-06-01",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        raise RuntimeError(f"API error {e.code}: {error_body}")
    except Exception as e:
        raise RuntimeError(f"API request failed: {e}")

    text = data["content"][0]["text"]

    if "```" in text:
        text = text.split("```")[1]
        if text.startswith("json"):
            text = text[4:]
    text = text.strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise RuntimeError(f"Failed to parse AI response: {text[:200]}")


def classify(items, use_ai=True, dir_name="Downloads"):
    """Classify items, falling back to extension-based if AI fails."""
    if use_ai:
        api_key = get_api_key()
        if not api_key:
            raise RuntimeError(
                "No API key found. Set ANTHROPIC_API_KEY env var, "
                "run `sortwise --setup-key`, or use --no-ai."
            )
        try:
            return classify_with_ai(items, api_key, dir_name), True
        except RuntimeError:
            return classify_by_extension(items), False
    return classify_by_extension(items), False


def build_plan(items, classification, age_days, downloads_dir=None):
    """Build a list of (src, dest) moves without executing them."""
    target = downloads_dir or Path.home() / "Downloads"
    moves = []
    old_dir = target / "_old"

    for item in items:
        name = item["name"]
        src = target / name
        category = classification.get(name, "other")

        if item["age_days"] > age_days:
            dest = old_dir / category / name
        else:
            dest = target / category / name

        if src == dest or not src.exists():
            continue
        moves.append((src, dest))

    return moves


def execute_moves(moves, downloads_dir=None):
    """Execute planned file moves, handling name collisions."""
    target = downloads_dir or Path.home() / "Downloads"
    dir_name = target.name
    moved = 0
    created_categories = set()
    for src, dest in moves:
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            stem = dest.stem
            suffix = dest.suffix
            i = 1
            while dest.exists():
                dest = dest.with_name(f"{stem} ({i}){suffix}")
                i += 1
        shutil.move(str(src), str(dest))
        moved += 1

        try:
            rel = dest.parent.relative_to(target)
            created_categories.add(rel.parts[0])
        except (ValueError, IndexError):
            pass

    # Save created categories per directory
    if created_categories:
        cfg = load_config()
        by_dir = cfg.get("category_folders_by_dir", {})
        existing = set(by_dir.get(dir_name, []))
        existing.update(created_categories)
        by_dir[dir_name] = sorted(existing)
        cfg["category_folders_by_dir"] = by_dir
        # Also update legacy key for Downloads
        if dir_name == "Downloads":
            legacy = set(cfg.get("category_folders", []))
            legacy.update(created_categories)
            cfg["category_folders"] = sorted(legacy)
        save_config(cfg)

    return moved


def tidy_directory(target_dir, use_ai=True, age_days=30, dry_run=False):
    """Run the full tidy pipeline on a single directory. Returns (items_found, moves, moved_count)."""
    items = scan_directory(target_dir)
    if not items:
        return 0, [], 0

    classification, _ = classify(items, use_ai=use_ai, dir_name=target_dir.name)
    moves = build_plan(items, classification, age_days, downloads_dir=target_dir)

    if dry_run or not moves:
        return len(items), moves, 0

    moved = execute_moves(moves, downloads_dir=target_dir)
    return len(items), moves, moved


def tidy_all(use_ai=True, age_days=30, dry_run=False):
    """Run tidy on all enabled directories. Returns dict of dir_name -> (items, moves, moved)."""
    results = {}
    for target_dir in get_enabled_dirs():
        results[target_dir.name] = tidy_directory(target_dir, use_ai, age_days, dry_run)

    # Log run
    if not dry_run:
        total_moved = sum(r[2] for r in results.values())
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        LOG_FILE.write_text(json.dumps({
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "files_moved": total_moved,
            "directories": {k: {"found": v[0], "moved": v[2]} for k, v in results.items()},
        }, indent=2))

    return results


def get_last_run():
    """Return last run info or None."""
    if LOG_FILE.exists():
        try:
            return json.loads(LOG_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return None


def format_plan(moves, downloads_dir=None):
    """Format a plan into a human-readable string."""
    target = downloads_dir or Path.home() / "Downloads"
    if not moves:
        return "Nothing to move — already tidy!"

    by_dest = {}
    for src, dest in moves:
        folder = str(dest.parent.relative_to(target))
        by_dest.setdefault(folder, []).append(src.name)

    lines = [f"{len(moves)} files to organize:\n"]
    for folder in sorted(by_dest):
        lines.append(f"  📁 {folder}/")
        for fname in sorted(by_dest[folder]):
            lines.append(f"     ↳ {fname}")
    return "\n".join(lines)
