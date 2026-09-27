APP := build/UsageBar.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app run install uninstall test print clean

app:
	./scripts/build-app.sh

run: app
	-pkill -x UsageBattery
	-pkill -x UsageBar
	open "$(APP)"

install: app
	-pkill -x UsageBattery
	-pkill -x UsageBar
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/UsageBar.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/UsageBar.app"
	@echo "Installed to $(INSTALL_DIR)/UsageBar.app"

uninstall:
	-pkill -x UsageBattery
	-pkill -x UsageBar
	rm -rf "$(INSTALL_DIR)/UsageBar.app"

test:
	swift test

print:
	swift run -c release UsageBar --print

clean:
	rm -rf .build build
