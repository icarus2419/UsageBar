APP := build/Usage Battery.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app run install uninstall test print clean

app:
	./scripts/build-app.sh

run: app
	-pkill -x UsageBattery
	open "$(APP)"

install: app
	-pkill -x UsageBattery
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/Usage Battery.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/Usage Battery.app"
	@echo "Installed to $(INSTALL_DIR)/Usage Battery.app"

uninstall:
	-pkill -x UsageBattery
	rm -rf "$(INSTALL_DIR)/Usage Battery.app"

test:
	swift test

print:
	swift run -c release UsageBattery --print

clean:
	rm -rf .build build
