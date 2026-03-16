################################################################################
# vmrestore - Build, Install & Deploy
#
# Usage:
#   make install                        Install directly (any distro)
#   make uninstall                      Remove installation
#   make package                        Build .deb package
#   make deploy TARGET=root@host       SCP + install on target host
#   make clean                          Remove build artifacts
#   make version                        Show current version
#
# The version is read from VERSION in vmrestore.sh.
################################################################################

PKG_NAME    := vmrestore
VERSION     := $(shell grep '^readonly VERSION=' vmrestore.sh | head -1 | sed 's/.*"\(.*\)"/\1/')
ARCH        := all
INSTALL_DIR := /opt/vmrestore
BUILD_DIR   := build
PKG_DIR     := $(BUILD_DIR)/$(PKG_NAME)_$(VERSION)_$(ARCH)
DEB_FILE    := $(PKG_DIR).deb

.PHONY: package clean deploy version install uninstall

version:
	@echo "$(PKG_NAME) $(VERSION)"

package: clean
	@echo "=== Building $(PKG_NAME) $(VERSION) ==="

	# --- Directory structure ---
	mkdir -p $(PKG_DIR)$(INSTALL_DIR)
	mkdir -p $(PKG_DIR)/DEBIAN

	# --- Main script (750: root + libvirt group, no world) ---
	install -m 750 vmrestore.sh            $(PKG_DIR)$(INSTALL_DIR)/

	# --- Documentation ---
	install -m 644 vmrestore.md            $(PKG_DIR)$(INSTALL_DIR)/
	mkdir -p $(PKG_DIR)$(INSTALL_DIR)/docs
	install -m 644 docs/vibe-coded.png     $(PKG_DIR)$(INSTALL_DIR)/docs/

	# --- DEBIAN metadata ---
	sed 's/__VERSION__/$(VERSION)/' debian/control > $(PKG_DIR)/DEBIAN/control
	install -m 755 debian/postinst         $(PKG_DIR)/DEBIAN/
	install -m 755 debian/postrm           $(PKG_DIR)/DEBIAN/

	# --- Build ---
	dpkg-deb --build --root-owner-group $(PKG_DIR)

	@echo ""
	@echo "=== Package built: $(DEB_FILE) ==="
	@echo "    Size: $$(du -h $(DEB_FILE) | cut -f1)"
	@echo ""
	@echo "To deploy:  make deploy TARGET=root@host"

deploy:
	@test -n "$(TARGET)" || { echo "Usage: make deploy TARGET=hostname"; echo "Example: make deploy TARGET=root@host"; exit 1; }
	@test -f "$(DEB_FILE)" || { echo "No package found. Run 'make package' first."; exit 1; }
	@echo "=== Deploying $(PKG_NAME) $(VERSION) to $(TARGET) ==="
	scp $(DEB_FILE) $(TARGET):/tmp/$(PKG_NAME)_$(VERSION)_$(ARCH).deb
	ssh -t $(TARGET) "sudo dpkg -i /tmp/$(PKG_NAME)_$(VERSION)_$(ARCH).deb && rm -f /tmp/$(PKG_NAME)_$(VERSION)_$(ARCH).deb"
	@echo ""
	@echo "=== Deployed $(PKG_NAME) $(VERSION) to $(TARGET) ==="

clean:
	rm -rf $(BUILD_DIR)

install:
	@echo "=== Installing $(PKG_NAME) $(VERSION) to $(INSTALL_DIR) ==="
	@test "$$(id -u)" = "0" || { echo "Error: make install must be run as root (use sudo)"; exit 1; }

	# --- Install files ---
	mkdir -p $(INSTALL_DIR)
	mkdir -p $(INSTALL_DIR)/docs
	install -m 750 vmrestore.sh            $(INSTALL_DIR)/
	install -m 644 vmrestore.md            $(INSTALL_DIR)/
	install -m 644 docs/vibe-coded.png     $(INSTALL_DIR)/docs/

	# --- PATH symlink ---
	ln -sf $(INSTALL_DIR)/vmrestore.sh /usr/local/bin/vmrestore

	# --- Ownership and permissions ---
	@if getent group libvirt >/dev/null 2>&1; then \
		chown -R root:libvirt $(INSTALL_DIR); \
	else \
		chown -R root:root $(INSTALL_DIR); \
	fi
	chmod 750 $(INSTALL_DIR)

	# --- Log directory ---
	mkdir -p /var/log/vmrestore
	@if getent group libvirt >/dev/null 2>&1; then \
		chown root:libvirt /var/log/vmrestore; \
	fi
	chmod 750 /var/log/vmrestore

	@echo ""
	@echo "=== $(PKG_NAME) $(VERSION) installed ==="
	@echo ""
	@echo "  Install path:  $(INSTALL_DIR)/"
	@echo "  Command:       vmrestore --help"
	@echo "  Logs:          /var/log/vmrestore/"
	@echo ""

uninstall:
	@echo "=== Uninstalling $(PKG_NAME) from $(INSTALL_DIR) ==="
	@test "$$(id -u)" = "0" || { echo "Error: make uninstall must be run as root (use sudo)"; exit 1; }

	# --- Remove installed files ---
	rm -f /usr/local/bin/vmrestore
	rm -rf $(INSTALL_DIR)
	rm -rf /var/log/vmrestore

	@echo ""
	@echo "=== $(PKG_NAME) uninstalled ==="
	@echo ""
