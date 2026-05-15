.PHONY: install
install:
	zig build --prefix zig-release --release=safe
	sudo install -m 755 ./zig-release/bin/taskbar /opt/bin/taskbar

.PHONY: install-debug
install-debug:
	zig build
	sudo install -m 755 ./zig-out/bin/taskbar /opt/bin/taskbar

.PHONY: update-deps
update-deps:
	rm -rf zig-pkg/zix11-*
	zig fetch --save git+https://github.com/baverman/zix11.git
