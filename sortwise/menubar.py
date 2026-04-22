"""macOS menu bar app for sortwise."""

import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

import rumps

from . import __version__
from .core import (
    scan_downloads,
    classify,
    build_plan,
    execute_moves,
    get_last_run,
    load_config,
    save_config,
    get_api_key,
    DEFAULT_DOWNLOADS,
    CONFIG_DIR,
)


class SortwiseApp(rumps.App):
    def __init__(self):
        super().__init__("🧹")
        self.cfg = load_config()
        self.age_days = self.cfg.get("age_days", 30)
        self.use_ai = self.cfg.get("use_ai", True)
        self.auto_interval = self.cfg.get("auto_interval_minutes", 240)
        self.auto_enabled = self.cfg.get("auto_enabled", True)
        self._last_tidy_time = None
        self._file_count = 0
        self._running = False

        # Build menu
        self.status_item = rumps.MenuItem("Scanning...", callback=None)
        self.status_item.set_callback(None)
        self.last_run_item = rumps.MenuItem("Last run: never", callback=None)
        self.last_run_item.set_callback(None)

        self.tidy_button = rumps.MenuItem("Tidy Now", callback=self.on_tidy)
        self.preview_button = rumps.MenuItem("Preview...", callback=self.on_preview)

        self.auto_toggle = rumps.MenuItem(
            f"Auto-tidy: every {self.auto_interval // 60}h",
            callback=self.on_toggle_auto,
        )
        self.auto_toggle.state = self.auto_enabled

        self.ai_toggle = rumps.MenuItem("AI classification", callback=self.on_toggle_ai)
        self.ai_toggle.state = self.use_ai

        self.open_downloads = rumps.MenuItem("Open Downloads", callback=self.on_open_downloads)
        self.open_config = rumps.MenuItem("Open Config Folder", callback=self.on_open_config)

        self.menu = [
            self.status_item,
            self.last_run_item,
            None,
            self.tidy_button,
            self.preview_button,
            None,
            self.auto_toggle,
            self.ai_toggle,
            None,
            self.open_downloads,
            self.open_config,
        ]

        self._update_status()
        self._update_last_run()

    def _save_prefs(self):
        cfg = load_config()
        cfg["age_days"] = self.age_days
        cfg["use_ai"] = self.use_ai
        cfg["auto_interval_minutes"] = self.auto_interval
        cfg["auto_enabled"] = self.auto_enabled
        save_config(cfg)

    def _update_status(self):
        try:
            items = scan_downloads()
            self._file_count = len(items)
            self.status_item.title = f"📁 {self._file_count} files in Downloads"
        except Exception:
            self.status_item.title = "📁 Unable to scan"

    def _update_last_run(self):
        info = get_last_run()
        if info:
            ts = info.get("timestamp", "")
            moved = info.get("files_moved", 0)
            try:
                dt = datetime.fromisoformat(ts)
                ago = datetime.now() - dt
                if ago.days > 0:
                    ago_str = f"{ago.days}d ago"
                elif ago.seconds >= 3600:
                    ago_str = f"{ago.seconds // 3600}h ago"
                elif ago.seconds >= 60:
                    ago_str = f"{ago.seconds // 60}m ago"
                else:
                    ago_str = "just now"
                self.last_run_item.title = f"Last run: {ago_str} ({moved} moved)"
            except (ValueError, TypeError):
                self.last_run_item.title = f"Last run: {ts}"
        else:
            self.last_run_item.title = "Last run: never"

    def _run_tidy(self, dry_run=False):
        if self._running:
            return None
        self._running = True
        try:
            items = scan_downloads()
            if not items:
                return "Downloads folder is empty!"

            classification, used_ai = classify(items, use_ai=self.use_ai)
            moves = build_plan(items, classification, self.age_days)

            if not moves:
                return "Nothing to move — Downloads is tidy!"

            if dry_run:
                from .core import format_plan
                return format_plan(moves)

            moved = execute_moves(moves)
            self._update_status()
            self._update_last_run()
            return f"✅ Organized {moved} files!"
        except RuntimeError as e:
            return f"Error: {e}"
        finally:
            self._running = False

    def on_tidy(self, _):
        self.title = "🧹⏳"
        self.tidy_button.title = "Running..."

        def do_tidy():
            result = self._run_tidy(dry_run=False)
            rumps.notification(
                title="sortwise",
                subtitle="",
                message=result or "Done",
            )
            self.title = "🧹"
            self.tidy_button.title = "Tidy Now"
            self._update_status()
            self._update_last_run()

        threading.Thread(target=do_tidy, daemon=True).start()

    def on_preview(self, _):
        self.title = "🧹⏳"

        def do_preview():
            result = self._run_tidy(dry_run=True)
            rumps.notification(
                title="sortwise preview",
                subtitle="",
                message=result[:256] if result else "Nothing to organize",
            )
            self.title = "🧹"

        threading.Thread(target=do_preview, daemon=True).start()

    def on_toggle_auto(self, sender):
        self.auto_enabled = not self.auto_enabled
        sender.state = self.auto_enabled
        self._save_prefs()

    def on_toggle_ai(self, sender):
        self.use_ai = not self.use_ai
        sender.state = self.use_ai
        self._save_prefs()

    def on_open_downloads(self, _):
        subprocess.run(["open", str(DEFAULT_DOWNLOADS)])

    def on_open_config(self, _):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        subprocess.run(["open", str(CONFIG_DIR)])

    @rumps.timer(300)  # check every 5 minutes
    def auto_tidy(self, _):
        self._update_status()
        self._update_last_run()

        if not self.auto_enabled:
            return

        info = get_last_run()
        if info:
            try:
                dt = datetime.fromisoformat(info["timestamp"])
                elapsed = (datetime.now() - dt).total_seconds()
                if elapsed < self.auto_interval * 60:
                    return
            except (ValueError, TypeError, KeyError):
                pass

        # Time to auto-tidy
        result = self._run_tidy(dry_run=False)
        if result and "Organized" in result:
            rumps.notification(
                title="sortwise",
                subtitle="Auto-tidy",
                message=result,
            )


def main():
    if not get_api_key():
        rumps.alert(
            title="sortwise",
            message="No API key configured.\n\n"
            "Run in terminal:\n"
            "  sortwise --setup-key\n\n"
            "Or set ANTHROPIC_API_KEY environment variable.\n\n"
            "The app will use extension-based sorting until a key is set.",
        )
    SortwiseApp().run()


if __name__ == "__main__":
    main()
