APP := build/Claude Usage.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app install run print previews clean

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
