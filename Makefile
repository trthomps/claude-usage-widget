APP := build/Claude Usage.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app install run print previews clean kde-install kde-uninstall kde-test

app:
	./scripts/build-app.sh

install: app
	mkdir -p "$(INSTALL_DIR)"
	-pkill -x ClaudeUsage
	rm -rf "$(INSTALL_DIR)/Claude Usage.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/Claude Usage.app"
	@echo "Installed to $(INSTALL_DIR)/Claude Usage.app"

run: app
	-pkill -x ClaudeUsage
	open "$(APP)"

print:
	swift run -c release ClaudeUsage --print

previews:
	swift run -c release ClaudeUsage --render-previews docs

clean:
	rm -rf .build build

# KDE Plasma 6 widget (see kde/README.md)
KDE_ID := dev.claudeusage.plasmoid

kde-install:
	if kpackagetool6 -t Plasma/Applet -s $(KDE_ID) >/dev/null 2>&1; then \
		kpackagetool6 -t Plasma/Applet -u kde/package; \
	else \
		kpackagetool6 -t Plasma/Applet -i kde/package; \
	fi
	@echo "Installed. Add \"Claude Usage\" from Add Widgets. After an upgrade, restart plasmashell: systemctl --user restart plasma-plasmashell"

kde-uninstall:
	kpackagetool6 -t Plasma/Applet -r $(KDE_ID)

kde-test:
	node kde/test/usage.test.js
