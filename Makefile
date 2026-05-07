.PHONY: install
install:
	zig build --prefix zig-release --release=safe
	sudo install -m 755 ./zig-release/bin/taskbar /opt/bin/taskbar

.PHONY: install-debug
install-debug:
	zig build
	sudo install -m 755 ./zig-out/bin/taskbar /opt/bin/taskbar
