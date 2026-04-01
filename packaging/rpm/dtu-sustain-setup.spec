Name:           dtu-sustain-setup
Version:        1.0.0
Release:        1%{?dist}
Summary:        DTU Sustain Linux workstation setup tool
License:        MIT
URL:            https://github.com/DTU-Sustain/DTU-Umbrella
BuildArch:      noarch
Source0:        dtu-sustain-setup-%{version}.tar.gz

Requires:       python3 >= 3.10
Requires:       python3-qt6
Requires:       bash
Requires:       polkit

Recommends:     realmd
Recommends:     sssd
Recommends:     sssd-ad
Recommends:     adcli
Recommends:     krb5-client
Recommends:     cifs-utils
Recommends:     cups
Recommends:     samba-client
Recommends:     xrdp
Recommends:     xorgxrdp

%description
A graphical setup utility for DTU Sustain Linux workstations.
Provides modules for domain join (WIN.DTU.DK), Q-Drive mapping,
printer setup (Brother P950NW, FollowMe), Microsoft Defender,
PolicyKit configuration, OneDrive for Business, and RDP
(xrdp + KDE Plasma remote desktop).

The application appears in the system application menu for all
users (including domain users). Admin modules use polkit for
privilege escalation.

%prep
%setup -q -n dtu-sustain-setup-%{version}

%install
# Application
install -d %{buildroot}/opt/dtu-sustain-setup
cp -r src/dtu_sustain_setup %{buildroot}/opt/dtu-sustain-setup/
cp -r scripts %{buildroot}/opt/dtu-sustain-setup/
cp -r data %{buildroot}/opt/dtu-sustain-setup/

# Launcher
install -d %{buildroot}/opt/dtu-sustain-setup/bin
install -m 755 bin/dtu-sustain-setup %{buildroot}/opt/dtu-sustain-setup/bin/

# Symlink to /usr/bin
install -d %{buildroot}%{_bindir}
ln -sf /opt/dtu-sustain-setup/bin/dtu-sustain-setup %{buildroot}%{_bindir}/dtu-sustain-setup

# Desktop file → visible to ALL users
install -d %{buildroot}%{_datadir}/applications
install -m 644 data/dtu-sustain-setup.desktop %{buildroot}%{_datadir}/applications/

# Icon
install -d %{buildroot}%{_datadir}/icons/hicolor/scalable/apps
install -m 644 data/dtu-sustain-setup.svg %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/

# Polkit policy
install -d %{buildroot}%{_datadir}/polkit-1/actions
install -m 644 data/dk.dtu.sustain.setup.policy %{buildroot}%{_datadir}/polkit-1/actions/

%post
# Update icon cache and desktop database
gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor 2>/dev/null || true
update-desktop-database %{_datadir}/applications 2>/dev/null || true

%postun
gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor 2>/dev/null || true
update-desktop-database %{_datadir}/applications 2>/dev/null || true

%files
/opt/dtu-sustain-setup/
%{_bindir}/dtu-sustain-setup
%{_datadir}/applications/dtu-sustain-setup.desktop
%{_datadir}/icons/hicolor/scalable/apps/dtu-sustain-setup.svg
%{_datadir}/polkit-1/actions/dk.dtu.sustain.setup.policy

%changelog
* Wed Mar 18 2026 DTU Sustain IT <support@sustain.dtu.dk> - 1.0.0-1
- Initial release
- Modules: Domain Join, Q-Drive, Brother P950NW, Defender, PolicyKit,
  FollowMe printers, OneDrive for Business, RDP (xrdp)
- PyQt6 GUI with live log output
- Auto-distro-detection (Ubuntu 24.04 / openSUSE Tumbleweed)
