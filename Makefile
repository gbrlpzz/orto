APP := build/Orto.app
# A real signing identity keeps macOS permissions across rebuilds; ad-hoc ("-") works but re-prompts.
SIGN_ID ?= -

.PHONY: build install uninstall clean

build:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/orto $(APP)/Contents/MacOS/orto
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN_ID)" $(APP)

install: build
	scripts/install.sh

uninstall:
	scripts/install.sh --remove

clean:
	rm -rf .build build
