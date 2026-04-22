.PHONY: install install-menubar uninstall app app-uninstall launchd-install launchd-uninstall clean

PYTHON := python3
PIPX := pipx
APP_NAME := Sortwise
APP_PATH := /Applications/$(APP_NAME).app

# Install CLI only (zero dependencies — uses Python stdlib)
install:
	$(PIPX) install . --force

# Install CLI + Python menu bar fallback
install-menubar:
	$(PIPX) install ".[menubar]" --force

# Uninstall CLI
uninstall:
	$(PIPX) uninstall sortwise || true

# Build and install native macOS menu bar app
app: install
	@echo "Building native menu bar app..."
	@mkdir -p "$(APP_PATH)/Contents/MacOS"
	@mkdir -p "$(APP_PATH)/Contents/Resources"
	@cp macos-app/Info.plist "$(APP_PATH)/Contents/Info.plist"
	@swiftc -parse-as-library -o "$(APP_PATH)/Contents/MacOS/launch" \
		macos-app/Sortwise.swift \
		-framework Cocoa -framework UserNotifications -O
	@# Generate app icon
	@$(PYTHON) macos-app/generate_icon.py
	@echo "✅ Installed to $(APP_PATH)"
	@echo "   Open it from Applications or Spotlight."

# Remove the menu bar app
app-uninstall:
	@osascript -e 'tell application "$(APP_NAME)" to quit' 2>/dev/null || true
	@sleep 1
	@rm -rf "$(APP_PATH)"
	@echo "✅ Removed $(APP_NAME).app"

# Install launchd auto-tidy (runs every 4 hours, CLI only — no menu bar app needed)
launchd-install:
	@SCRIPT_PATH=$$(which sortwise) && \
	sed "s|__SCRIPT__|$$SCRIPT_PATH|g" launchd/com.sortwise.plist > ~/Library/LaunchAgents/com.sortwise.plist
	launchctl load ~/Library/LaunchAgents/com.sortwise.plist
	@echo "✅ Auto-tidy installed (every 4 hours)"

launchd-uninstall:
	launchctl unload ~/Library/LaunchAgents/com.sortwise.plist 2>/dev/null || true
	rm -f ~/Library/LaunchAgents/com.sortwise.plist
	@echo "✅ Auto-tidy removed"

clean:
	rm -rf build dist *.egg-info
