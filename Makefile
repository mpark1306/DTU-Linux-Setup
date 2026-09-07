###############################################################################
# DTU Linux Setup – Makefile
###############################################################################

PREFIX      ?= /opt/dtu-sustain-setup
DESTDIR     ?=
BINDIR      ?= /usr/bin
APPDIR      ?= /usr/share/applications
ICONDIR     ?= /usr/share/icons/hicolor/scalable/apps
POLICYDIR   ?= /usr/share/polkit-1/actions

VERSION     := 1.6.0

.PHONY: help install uninstall deb rpm clean check-version lint test

help:
	@echo "DTU Linux Setup – Build targets"
	@echo ""
	@echo "  make install        Install to $(PREFIX) (run as root)"
	@echo "  make uninstall      Remove installation"
	@echo "  make deb            Build DEB package (Ubuntu)"
	@echo "  make run            Run from source (development)"
	@echo "  make check-version  Verify all version strings agree"
	@echo "  make lint           shellcheck all scripts + byte-compile Python"
	@echo "  make test           Guard + smoke tests (no root, no network)"
	@echo "  make clean          Clean build artifacts"

# ─── Checks ─────────────────────────────────────────────────────────────────
# VERSION above is the single source of truth. These files repeat it because
# they are read by tools that cannot see the Makefile; this target makes the
# duplication safe by failing the build when they drift.

check-version:
	@echo "Makefile VERSION:      $(VERSION)"
	@PYPROJECT_V="$$(grep -E '^version[[:space:]]*=' pyproject.toml | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"; \
	 INIT_V="$$(grep -E '^__version__[[:space:]]*=' src/dtu_sustain_setup/__init__.py | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"; \
	 echo "pyproject.toml:        $$PYPROJECT_V"; \
	 echo "__init__.py:           $$INIT_V"; \
	 RC=0; \
	 [ "$$PYPROJECT_V" = "$(VERSION)" ] || { echo "❌ pyproject.toml ($$PYPROJECT_V) != Makefile ($(VERSION))"; RC=1; }; \
	 [ "$$INIT_V" = "$(VERSION)" ]      || { echo "❌ __init__.py ($$INIT_V) != Makefile ($(VERSION)) — this string is shown in the GUI header"; RC=1; }; \
	 [ $$RC -eq 0 ] && echo "✅ All version strings agree."; \
	 exit $$RC

test:
	@echo "── Guard: no internal values in tracked files ───────────────"
	bash tests/check-no-internal-values.sh
	@echo ""
	@echo "── Bash: site configuration ─────────────────────────────────"
	bash tests/test_site_conf.sh
	@echo ""
	@echo "── Shell: scripts (statisk + adfærd) ───────────────────────"
	PYTHONPATH=src python3 -m unittest tests.test_scripts -v 2>&1 | tail -5
	@echo ""
	@echo "── Python: env loader ───────────────────────────────────────"
	PYTHONPATH=src python3 -m unittest discover -s tests -v

lint:
	@echo "Running shellcheck..."
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed: sudo apt install shellcheck"; exit 1; }
	shellcheck --severity=warning --external-sources \
	@echo "Byte-compiling Python..."
	python3 -m compileall -q src/dtu_sustain_setup
	@echo "✅ Lint passed."

# ─── Install / uninstall ────────────────────────────────────────────────────

install:
	@echo "Installing DTU Linux Setup to $(DESTDIR)$(PREFIX)..."

	# Application files
	install -d $(DESTDIR)$(PREFIX)
	cp -r src/dtu_sustain_setup $(DESTDIR)$(PREFIX)/
	cp -r scripts $(DESTDIR)$(PREFIX)/
	cp -r data $(DESTDIR)$(PREFIX)/

	# Launcher
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 bin/dtu-sustain-setup $(DESTDIR)$(PREFIX)/bin/

	# Ensure scripts are executable
	find $(DESTDIR)$(PREFIX)/scripts -name '*.sh' -exec chmod 755 {} +

	# Symlink to PATH
	install -d $(DESTDIR)$(BINDIR)
	ln -sf $(PREFIX)/bin/dtu-sustain-setup $(DESTDIR)$(BINDIR)/dtu-sustain-setup

	# Desktop file (visible to ALL users including domain users)
	install -d $(DESTDIR)$(APPDIR)
	install -m 644 data/dtu-sustain-setup.desktop $(DESTDIR)$(APPDIR)/

	# Icon
	install -d $(DESTDIR)$(ICONDIR)
	install -m 644 data/dtu-sustain-setup.svg $(DESTDIR)$(ICONDIR)/

	# Polkit policy
	install -d $(DESTDIR)$(POLICYDIR)
	install -m 644 data/dk.dtu.sustain.setup.policy $(DESTDIR)$(POLICYDIR)/

	# Refresh caches
	gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
	update-desktop-database $(APPDIR) 2>/dev/null || true

	@echo "✅ Installed to $(PREFIX)"
	@echo "   Desktop entry: $(APPDIR)/dtu-sustain-setup.desktop"
	@echo "   Launcher: $(BINDIR)/dtu-sustain-setup"

uninstall:
	@echo "Removing DTU Linux Setup..."
	rm -rf $(DESTDIR)$(PREFIX)
	rm -f  $(DESTDIR)$(BINDIR)/dtu-sustain-setup
	rm -f  $(DESTDIR)$(APPDIR)/dtu-sustain-setup.desktop
	rm -f  $(DESTDIR)$(ICONDIR)/dtu-sustain-setup.svg
	rm -f  $(DESTDIR)$(POLICYDIR)/dk.dtu.sustain.setup.policy
	gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
	update-desktop-database $(APPDIR) 2>/dev/null || true
	@echo "✅ Uninstalled."

# ─── Development ────────────────────────────────────────────────────────────

run:
	PYTHONPATH=src python3 -m dtu_sustain_setup

# ─── Package building ──────────────────────────────────────────────────────

deb:
	@echo "Building DEB package with dpkg-deb..."
	$(eval DEB_ROOT := /tmp/dtu-sustain-setup-deb)
	rm -rf $(DEB_ROOT)

	# Application files
	install -d $(DEB_ROOT)/opt/dtu-sustain-setup
	cp -r src/dtu_sustain_setup $(DEB_ROOT)/opt/dtu-sustain-setup/
	cp -r scripts $(DEB_ROOT)/opt/dtu-sustain-setup/
	cp -r data $(DEB_ROOT)/opt/dtu-sustain-setup/

	# Launcher
	install -d $(DEB_ROOT)/opt/dtu-sustain-setup/bin
	install -m 755 bin/dtu-sustain-setup $(DEB_ROOT)/opt/dtu-sustain-setup/bin/

	# Ensure scripts are executable
	find $(DEB_ROOT)/opt/dtu-sustain-setup/scripts -name '*.sh' -exec chmod 755 {} +

	# Symlink to /usr/bin
	install -d $(DEB_ROOT)/usr/bin
	ln -sf /opt/dtu-sustain-setup/bin/dtu-sustain-setup $(DEB_ROOT)/usr/bin/dtu-sustain-setup

	# Desktop file
	install -d $(DEB_ROOT)/usr/share/applications
	install -m 644 data/dtu-sustain-setup.desktop $(DEB_ROOT)/usr/share/applications/

	# Icon
	install -d $(DEB_ROOT)/usr/share/icons/hicolor/scalable/apps
	install -m 644 data/dtu-sustain-setup.svg $(DEB_ROOT)/usr/share/icons/hicolor/scalable/apps/

	# Polkit policy
	install -d $(DEB_ROOT)/usr/share/polkit-1/actions
	install -m 644 data/dk.dtu.sustain.setup.policy $(DEB_ROOT)/usr/share/polkit-1/actions/

	# Site-config template (for IT admins to fill in as /etc/dtu-setup/site.conf).
	# The DTU Sustain / AIT profiles are distributed out-of-band, not shipped here.
	install -d $(DEB_ROOT)/usr/share/doc/dtu-sustain-setup/examples
	install -m 644 data/site.conf.example         $(DEB_ROOT)/usr/share/doc/dtu-sustain-setup/examples/
	install -m 644 examples/dtu-runtime.env.example $(DEB_ROOT)/usr/share/doc/dtu-sustain-setup/examples/
	install -m 644 README.md                       $(DEB_ROOT)/usr/share/doc/dtu-sustain-setup/
	install -m 644 LICENSE                         $(DEB_ROOT)/usr/share/doc/dtu-sustain-setup/

	# DEBIAN control files
	install -d $(DEB_ROOT)/DEBIAN
	@echo "Package: dtu-sustain-setup"             >  $(DEB_ROOT)/DEBIAN/control
	@echo "Version: $(VERSION)"                    >> $(DEB_ROOT)/DEBIAN/control
	@echo "Section: admin"                         >> $(DEB_ROOT)/DEBIAN/control
	@echo "Priority: optional"                     >> $(DEB_ROOT)/DEBIAN/control
	@echo "Architecture: all"                      >> $(DEB_ROOT)/DEBIAN/control
	@echo "Maintainer: DTU Sustain IT <support@sustain.dtu.dk>" >> $(DEB_ROOT)/DEBIAN/control
	@echo "Depends: python3 (>= 3.10), python3-pyqt6, bash, policykit-1" >> $(DEB_ROOT)/DEBIAN/control
	@echo "Recommends: realmd, sssd, sssd-ad, adcli, krb5-user, cifs-utils, cups, samba-common-bin, xrdp, xorgxrdp" >> $(DEB_ROOT)/DEBIAN/control
	@echo "Description: DTU Sustain Linux workstation setup tool" >> $(DEB_ROOT)/DEBIAN/control
	@echo " A graphical setup utility for DTU Sustain Linux workstations." >> $(DEB_ROOT)/DEBIAN/control
	@echo " Provides modules for domain join, Q-Drive, printers, Defender," >> $(DEB_ROOT)/DEBIAN/control
	@echo " PolicyKit, home-directory sync, and RDP." >> $(DEB_ROOT)/DEBIAN/control

	# Post-install script
	@echo '#!/bin/sh'                                          >  $(DEB_ROOT)/DEBIAN/postinst
	@echo 'set -e'                                             >> $(DEB_ROOT)/DEBIAN/postinst
	@echo 'gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true' >> $(DEB_ROOT)/DEBIAN/postinst
	@echo 'update-desktop-database /usr/share/applications 2>/dev/null || true'      >> $(DEB_ROOT)/DEBIAN/postinst
	@echo 'install -d /etc/dtu-setup'                          >> $(DEB_ROOT)/DEBIAN/postinst
	@echo 'if [ ! -f /etc/dtu-setup/site.conf ]; then'         >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo ""'                                          >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "*** No /etc/dtu-setup/site.conf found ***"' >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "Modules that need site-specific values will refuse to run"' >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "until one exists. Either install the profile for your"'     >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "department (distributed separately by DTU IT):"'            >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "  sudo install -m 0644 dtu-<department>.env /etc/dtu-setup/site.conf"' >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "or start from the template and fill in the placeholders:"'  >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "  sudo install -m 0644 /usr/share/doc/dtu-sustain-setup/examples/site.conf.example /etc/dtu-setup/site.conf"' >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "Then set department:"'                      >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "  echo ait     | sudo tee /etc/dtu-setup/department"' >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo "  echo sustain | sudo tee /etc/dtu-setup/department"' >> $(DEB_ROOT)/DEBIAN/postinst
	@echo '  echo ""'                                          >> $(DEB_ROOT)/DEBIAN/postinst
	@echo 'fi'                                                 >> $(DEB_ROOT)/DEBIAN/postinst
	chmod 755 $(DEB_ROOT)/DEBIAN/postinst

	# Build .deb (use xz compression for Ubuntu compatibility)
	dpkg-deb --build --root-owner-group -Zxz $(DEB_ROOT) dtu-sustain-setup_$(VERSION)_all.deb
	rm -rf $(DEB_ROOT)
	@echo "✅ DEB package built: dtu-sustain-setup_$(VERSION)_all.deb"

rpm:
	@echo "Building RPM package..."
	@command -v rpmbuild >/dev/null || { echo "Install rpm-build first"; exit 1; }
	mkdir -p ~/rpmbuild/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
	# Create tarball
	tar czf ~/rpmbuild/SOURCES/dtu-sustain-setup-$(VERSION).tar.gz \
		--transform='s,^,dtu-sustain-setup-$(VERSION)/,' \
		src/ scripts/ data/ bin/ packaging/
	cp packaging/rpm/dtu-sustain-setup.spec ~/rpmbuild/SPECS/
	sed -i 's/^Version:[[:space:]]*.*/Version:        $(VERSION)/' ~/rpmbuild/SPECS/dtu-sustain-setup.spec
	rpmbuild -bb ~/rpmbuild/SPECS/dtu-sustain-setup.spec
	@echo "✅ RPM package built. Check ~/rpmbuild/RPMS/"

# ─── Clean ──────────────────────────────────────────────────────────────────

clean:
	rm -rf debian build dist *.egg-info
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
