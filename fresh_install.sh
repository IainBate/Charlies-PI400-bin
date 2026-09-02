#!/bin/bash
#
# fresh_install.sh - rebuild the Caravan Pi (hostname PI400) from a bare OS install
#
# WHAT THIS IS
#   A from-scratch record of everything that was set up on PI400 by hand,
#   turned into a script, so a full SD-card-dead / start-again disaster can
#   be recovered in one sitting instead of by memory. Captured 2026-09-02,
#   by SSHing into the live Pi (192.168.0.129 on the home LAN at the time)
#   and reading its actual installed packages, mounts, services and config -
#   same method used for HomePI4's fresh_install.sh, so treat that script as
#   the sibling reference if something here is unclear.
#
# HOW TO USE IT IF SOMETHING GOES WRONG PARTWAY THROUGH
#   Every step below prints a "--- STEP N: ... ---" banner and is written to
#   be safe to re-run (it checks whether it's already done and skips itself
#   if so). If a step fails: read the comment above it for context, then
#   either fix the underlying problem and re-run this whole script from the
#   top (earlier steps will just skip past themselves), or run the
#   individual command(s) from that step by hand.
#
#   Claude Code is installed as STEP 1, deliberately before anything else
#   that could go wrong, specifically so you have it available to help
#   debug the rest. If you hit a failure: open a terminal on the Pi (or SSH
#   in), cd to wherever this script lives, run `claude`, paste the error
#   Claude prints. It already has this script's context via the working
#   directory, plus it can read this file directly.
#
# PREREQUISITES (do these BEFORE running this script)
#   1. Flash a fresh "Raspberry Pi OS with desktop" image (NOT Lite - this
#      Pi boots straight into a desktop session via lightdm/wayland, that's
#      how it's actually used) with the Raspberry Pi Imager. Use the OS
#      customization options to set: hostname = PI400, username = pi,
#      enable SSH, and connect it to WiFi if not using Ethernet for this
#      first boot (you'll join the caravan's own network in STEP 4/manual
#      follow-ups once it's reachable). This was Debian 13 (trixie) based,
#      kernel 6.12, at time of writing.
#   2. Boot it, physically reattach the external USB "Caravan" drive (the
#      one with UUID matched in STEP 6 below - a single 4.6TB ext4 disk
#      mounted at /media/pi/Caravan, holding /media/pi/Caravan/films that
#      minidlna serves). Note this is the SAME physical drive HomePI4's
#      fstab also has an entry for (as a portable, occasionally-attached
#      backup target for films_backup) - if it's currently plugged into
#      HomePI4, move it back here first.
#   3. SSH in as `pi` (password auth is fine - see STEP 7's note on why no
#      key-based restore happens here), save this script somewhere like
#      /home/pi/fresh_install.sh - deliberately NOT inside ~/bin, since
#      STEP 8 below moves/replaces that directory - and run:
#        bash /home/pi/fresh_install.sh
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO
#   - It does not set up Samba/file sharing. Unlike HomePI4, this Pi has no
#     samba package installed and no smb.conf - minidlna (DLNA) plus
#     physically pulling the USB drive is the only file-access model here.
#   - It does not set up home_automation or heating_automation - those are
#     HomePI4-only private repos and have nothing to do with this Pi's job.
#   - It does not configure Tailscale. This Pi uses Raspberry Pi Connect
#     (the rpi-connect package, STEP 4) for remote screen-share/shell
#     instead - that's what actually gets you into it while it's away at a
#     campsite, not on the home LAN or Tailscale.
#   - It cannot restore ~/.ssh, deluge's web UI password, or the
#     NetworkManager WiFi profile for the caravan's own network
#     automatically - this Pi has no backup mechanism for its own /home or
#     /etc (only the films on the Caravan drive itself survive an SD card
#     death). Each of those is called out with manual recovery instructions
#     at the point it comes up below, and again in the summary at the end.
#   - It does not touch the Caravan drive's *contents* - it just needs to be
#     physically present and get mounted.
#
set -e

echo "=================================================================="
echo " fresh_install.sh - rebuilding the Caravan Pi (PI400) setup"
echo "=================================================================="
echo ""

# ---------------------------------------------------------------------------
# STEP 1: Claude Code CLI - installed first and deliberately, so that if
# anything below this point goes wrong, you already have a Claude Code
# session available on this machine to help fix it. All you'd need to do
# is log in.
# ---------------------------------------------------------------------------
echo "--- STEP 1: Claude Code CLI ---"
if ! command -v claude >/dev/null 2>&1; then
	sudo apt-get update -qq
	sudo apt-get install -y nodejs npm
	sudo npm install -g @anthropic-ai/claude-code
	echo "Claude Code installed."
else
	echo "Claude Code already installed, skipping."
fi
echo ""
echo ">>> If you haven't already, log in now (needs a browser on any device):"
echo ">>>   claude login"
echo ">>> From this point on, if any step below fails, you can run 'claude'"
echo ">>> in this directory, paste the error, and ask it to help - it can"
echo ">>> read this whole script for context."
echo ""
read -r -p "Press Enter to continue once Claude Code is installed (login can wait)... " _dummy || true

# ---------------------------------------------------------------------------
# STEP 2: cache sudo credentials for this session, so the many sudo calls
# below don't each stop to prompt for a password. (Unlike HomePI4, this Pi
# does not have passwordless sudo configured - it's never needed it, since
# nothing here currently runs unattended via cron. If you add a scheduled
# job later that needs sudo, e.g. reviving backup_PI, set that up then.)
# ---------------------------------------------------------------------------
echo "--- STEP 2: sudo ---"
sudo -v
# Keep the sudo timestamp alive for the rest of the script. Without
# passwordless sudo (see above), STEP 3's per-package install loop alone
# can run past sudo's ~15-minute default timeout on a slow connection,
# which would otherwise leave later steps (STEP 5, 7, 11) blocking on an
# unexpected password prompt despite this step's caching.
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
echo ""

# ---------------------------------------------------------------------------
# STEP 3: apt packages. This is the `apt-mark showmanual` list from the
# working Pi, captured 2026-09-02, grouped for readability, with the
# lowest-level base/lib packages (libc6, dpkg, systemd, coreutils and
# similar - hundreds of entries any Raspberry Pi OS image already has)
# deliberately left out rather than reproduced in full: they're guaranteed
# present already and would just be noise here. If you flashed the "with
# desktop" image variant (see PREREQUISITES), most of the rpd-*/lightdm/
# rpi-connect lines below will already be present and apt will just confirm
# them.
# ---------------------------------------------------------------------------
echo "--- STEP 3: apt packages ---"
echo ">>> NOTE: a few of these package names are tied to a specific version"
echo ">>> (e.g. gcc-14-base, linux-image-rpi-2712) and could have moved on"
echo ">>> by the time you're reading this. If apt says 'Unable to locate"
echo ">>> package X', that's expected drift, not a real problem - drop that"
echo ">>> one name from the PACKAGES array below (or ask Claude Code to find"
echo ">>> its current equivalent) and re-run."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

PACKAGES=(
	# --- Media serving (the actual point of this Pi) ---
	minidlna

	# --- Torrent downloads (deluge web UI - used to grab media while away
	# from home, without needing a full desktop session running) ---
	deluge deluge-console deluge-web deluged

	# --- Backup / sync / disk tools ---
	rsync udisks2 ntfs-3g dosfstools parted fdisk e2fsprogs cifs-utils

	# --- Video/media processing (convert_video, films_backup etc.) ---
	mkvtoolnix p7zip-full

	# --- Networking. This Pi roams between whatever WiFi it's near (a
	# campsite, the caravan's own onboard hotspot, home) rather than sitting
	# on one fixed network, so the WiFi firmware packages matter more here
	# than on HomePI4 ---
	network-manager nftables net-tools iproute2 iputils-ping ethtool
	wireless-tools wpasupplicant dhcpcd-base usb-modeswitch
	firmware-atheros firmware-brcm80211 firmware-libertas firmware-mediatek
	firmware-realtek

	# --- RAM/log management ---
	log2ram rpi-swap logrotate

	# --- Dev / build tools (used for compiling things like ffmpeg) ---
	build-essential gcc-14-base gdb pkg-config python-is-python3 python3-venv

	# --- Raspberry Pi hardware / GPIO / camera ---
	gpiod python3-gpiozero python3-libgpiod python3-rpi-lgpio
	python3-smbus2 python3-spidev v4l-utils rpicam-apps-lite fbset

	# --- Misc utilities used by scripts in ~/bin or day-to-day admin ---
	curl wget htop ncdu file strace dmidecode usbutils pciutils
	unzip zip tar cpio sed grep gzip vim-tiny nano less whiptail
	bash-completion locales tzdata ssh ssh-import-id ca-certificates

	# --- Desktop environment + remote access. This Pi boots to a desktop
	# (lightdm) rather than running headless. Remote access while away from
	# home is Raspberry Pi Connect (rpi-connect, see STEP 4) rather than
	# Tailscale - RealVNC server and wayvnc get pulled in automatically as
	# dependencies of rpi-connect / the rpd-* desktop meta-packages, so
	# aren't listed separately here ---
	lightdm rpi-connect bluez bluez-firmware
	rpd-applications rpd-developer rpd-graphics rpd-preferences rpd-theme
	rpd-utilities rpd-wayland-core rpd-wayland-extras rpd-x-core rpd-x-extras

	# --- Bootloader/firmware/Pi-specific ---
	cloud-init linux-headers-rpi-2712 linux-headers-rpi-v8
	linux-image-rpi-2712 linux-image-rpi-v8 raspberrypi-net-mods
	raspberrypi-sys-mods raspi-config raspi-firmware raspi-utils
	rpi-cloud-init-mods rpi-eeprom rpi-keyboard-config
	rpi-keyboard-fw-update rpi-loop-utils rpi-update rpi-usb-gadget
	rpifwcrypto

	# --- Base system (near-certainly already present on any Raspberry Pi
	# OS image, listed here only for completeness / faithfulness to the
	# original apt-mark showmanual capture) ---
	sudo cron cron-daemon-common systemd-timesyncd udev avahi-daemon
	console-setup keyboard-configuration
)

# Installed one at a time rather than as a single `apt-get install
# "${PACKAGES[@]}"` call: apt resolves the whole list as one transaction, so
# a single unresolvable name (see the version-drift warning above) would
# otherwise abort dependency resolution before ANY package installs, not
# just the stale one - and that failure wouldn't surface until much later,
# more confusingly, when STEP 11 tries to enable a service that was never
# actually installed.
FAILED_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
	sudo apt-get install -y "$pkg" || FAILED_PACKAGES+=("$pkg")
done
if [ ${#FAILED_PACKAGES[@]} -eq 0 ]; then
	echo "All apt packages installed."
else
	echo ">>> Failed to install: ${FAILED_PACKAGES[*]}"
	echo ">>> Likely the version drift warned about above - fix the names in"
	echo ">>> the PACKAGES array and re-run (already-installed packages are"
	echo ">>> skipped instantly), or continue on and revisit later."
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 4: Raspberry Pi Connect. This is how PI400 is reached remotely while
# it's away from home (screen sharing + remote shell via
# connect.raspberrypi.com) - install is scriptable, signing in is not
# (needs a browser). Don't skip this if you want to debug the Pi from
# anywhere other than whatever network it's currently sat on.
# ---------------------------------------------------------------------------
echo "--- STEP 4: Raspberry Pi Connect ---"
if command -v rpi-connect >/dev/null 2>&1; then
	echo "rpi-connect already installed (pulled in by STEP 3)."
else
	echo ">>> rpi-connect wasn't installed by STEP 3 - check the PACKAGES"
	echo ">>> array / apt output above."
fi
echo ""
echo ">>> Manual step needed: run 'rpi-connect signin', follow the login"
echo ">>> link it prints, and approve this device at connect.raspberrypi.com."
echo ">>> Once signed in, 'rpi-connect status' should show:"
echo ">>>   Signed in: yes"
echo ">>>   Screen sharing: allowed"
echo ">>>   Remote shell: allowed"
echo ""
read -r -p "Press Enter once 'rpi-connect signin' is done (or to skip for now)... " _dummy || true

# ---------------------------------------------------------------------------
# STEP 5: fstab entry for the Caravan drive. Only the custom line below is
# added - the /boot/firmware and / lines are auto-generated fresh by the Pi
# Imager for whatever SD card you flashed and shouldn't be touched here.
# The UUID is tied to the specific physical disk - if you've replaced the
# drive, find its new UUID with `sudo blkid` and update the line below
# before running this step.
# ---------------------------------------------------------------------------
echo "--- STEP 5: fstab ---"
FSTAB_MARKER="# --- fresh_install.sh: PI400 Caravan drive ---"
FSTAB_LINE="UUID=e2e2bddc-afad-404b-864e-fa3308db154c /media/pi/Caravan ext4 defaults,auto,users,exec,rw,nofail 0 0"
sudo mkdir -p /media/pi/Caravan
if grep -qF "$FSTAB_LINE" /etc/fstab 2>/dev/null; then
	echo "fstab already has this exact Caravan drive entry, skipping."
else
	sudo cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d)
	if grep -q "$FSTAB_MARKER" /etc/fstab; then
		# Marker's present but the UUID line differs from what's above - the
		# drive was replaced (see this step's comment) and the script was
		# re-run with an updated UUID. Drop the old marker+UUID pair so the
		# new one below doesn't just get appended alongside a stale entry.
		sudo sed -i "/^${FSTAB_MARKER//\//\\/}$/,+1d" /etc/fstab
		echo "Replacing stale Caravan drive fstab entry with the current UUID."
	fi
	{
		echo ""
		echo "$FSTAB_MARKER"
		echo "$FSTAB_LINE"
	} | sudo tee -a /etc/fstab > /dev/null
	echo "fstab updated (backup saved as /etc/fstab.bak.$(date +%Y%m%d))."
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 6: mount the Caravan drive. Its ownership (minidlna:minidlna) and
# permissions (0777) are already baked into the filesystem itself from when
# it was originally set up, not something this script needs to chown -
# unlike HomePI4, minidlna does NOT need adding to any group here, since
# minidlna just owns this drive outright rather than sharing group access
# with the pi user.
# ---------------------------------------------------------------------------
echo "--- STEP 6: mount /media/pi/Caravan ---"
if ! mountpoint -q /media/pi/Caravan; then
	sudo mount /media/pi/Caravan || true
fi
if mountpoint -q /media/pi/Caravan; then
	echo "/media/pi/Caravan mounted."
else
	echo "ERROR: /media/pi/Caravan did not mount. Is the drive physically"
	echo "attached? Check 'sudo blkid' matches the UUID in /etc/fstab (STEP 5)."
	echo "STEP 10's minidlna.conf points at /media/pi/Caravan/films - without"
	echo "this drive mounted, minidlna will have nothing to serve."
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 7: SSH access. There is no backup drive holding a copy of this Pi's
# own /home to restore a key from - as of the 2026-09-02 capture this Pi
# had NO authorized_keys at all and was reached purely by password auth.
# The one key below is the Mac that was used to inspect this Pi while
# writing this script; it's safe to commit (SSH public keys are not
# secret) and re-adding it here means at least that machine can get back
# in without you retyping the pi user's password. Add any other trusted
# device's public key the same way (one line each).
# ---------------------------------------------------------------------------
echo "--- STEP 7: SSH authorized_keys ---"
mkdir -p /home/pi/.ssh
chmod 700 /home/pi/.ssh
AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDRhibUGlvJ+hsAM2JMqLlf0bdedxt8E/eI5+EyXpbWf iain@iains-MacBook-Pro.local"
if ! grep -qF "$AUTHORIZED_KEY" /home/pi/.ssh/authorized_keys 2>/dev/null; then
	echo "$AUTHORIZED_KEY" >> /home/pi/.ssh/authorized_keys
	chmod 600 /home/pi/.ssh/authorized_keys
	echo "Added known public key to authorized_keys."
else
	echo "Known public key already present in authorized_keys, skipping."
fi
echo ""
echo ">>> This Pi has no SSH key of its OWN for cloning private repos - it"
echo ">>> doesn't need one, since STEP 8 below is a public repo over HTTPS"
echo ">>> and this Pi doesn't run home_automation/heating_automation."
echo ""
echo ">>> deluge's web UI auth (~/.config/deluge/auth) and this Pi's"
echo ">>> NetworkManager WiFi profiles aren't backed up anywhere either -"
echo ">>> see the summary at the end for what to do about each by hand."
echo ""

# ---------------------------------------------------------------------------
# STEP 8: clone ~/bin from GitHub. Public repo, plain HTTPS, no auth needed.
# This brings back every script in this repo, including this one,
# films_backup, and everything else currently in ~/bin.
# Note: at capture time the live Pi's ~/bin was NOT a git checkout (it had
# just been copied there by hand over time) - this step deliberately
# switches it to a git clone going forward, same as HomePI4, so future
# changes are actually version-controlled instead of drifting silently.
# ---------------------------------------------------------------------------
echo "--- STEP 8: clone ~/bin ---"
if [ ! -d /home/pi/bin/.git ]; then
	if [ -d /home/pi/bin ]; then
		mv /home/pi/bin /home/pi/bin.pre_fresh_install.$(date +%Y%m%d_%H%M%S)
		echo "Moved existing non-git ~/bin aside before cloning."
	fi
	git clone https://github.com/IainBate/Charlies-PI400-bin.git /home/pi/bin
	echo "~/bin cloned (git tracks each script's executable bit, so"
	echo "permissions come back correct without needing chmod here)."
else
	echo "~/bin is already a git checkout, pulling latest instead of cloning..."
	git -C /home/pi/bin pull --ff-only
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 9: crontab. At capture time this Pi had NO crontab at all (unlike
# HomePI4, nothing here runs on a schedule - backup_PI in ~/bin is a manual,
# not-currently-used script left over from an older /mnt/HDD-based setup
# that no longer exists on this Pi). Nothing to install. If you add
# scheduled jobs later, commit a crontab.txt to this repo the way
# Home-PI4-bin does and add a `crontab /home/pi/bin/crontab.txt` line here
# so it stays reproducible.
# ---------------------------------------------------------------------------
echo "--- STEP 9: crontab ---"
echo "No crontab.txt in this repo - nothing to install, matching the live"
echo "Pi's state at capture time. Current crontab:"
crontab -l 2>&1 || true
echo ""

# ---------------------------------------------------------------------------
# STEP 10: minidlna config. media_dir points at /media/pi/Caravan/films only.
# ---------------------------------------------------------------------------
echo "--- STEP 10: minidlna.conf ---"
sudo tee /etc/minidlna.conf > /dev/null <<'EOF'
media_dir=V,/media/pi/Caravan/films
db_dir=/var/cache/minidlna
log_dir=/var/log/minidlna
port=8200
friendly_name=CharliesMediaServer
album_art_names=Cover.jpg/cover.jpg/AlbumArtSmall.jpg/albumartsmall.jpg
album_art_names=AlbumArt.jpg/albumart.jpg/Album.jpg/album.jpg
album_art_names=Folder.jpg/folder.jpg/Thumb.jpg/thumb.jpg
EOF
echo "minidlna.conf written."
echo ""

# ---------------------------------------------------------------------------
# STEP 11: restart/enable services, so everything reconfigured above is live
# without needing a reboot, and comes back on its own after one.
# ---------------------------------------------------------------------------
echo "--- STEP 11: restart/enable services ---"
sudo systemctl enable --now minidlna
sudo systemctl enable --now deluged
sudo systemctl enable --now deluge-web
sudo systemctl restart minidlna
sudo systemctl restart log2ram || true
echo "Services enabled and restarted."
echo ""

# ---------------------------------------------------------------------------
# STEP 12: summary / what's left to do by hand
# ---------------------------------------------------------------------------
echo "=================================================================="
echo " fresh_install.sh: done. Manual follow-ups, if not already done:"
echo "=================================================================="
echo "  [ ] claude login                     (Claude Code, STEP 1)"
echo "  [ ] rpi-connect signin                (Raspberry Pi Connect, STEP 4)"
echo "  [ ] Reconnect this Pi to the caravan's own WiFi network. The"
echo "      NetworkManager profile for it ('Charlie.nmconnection' at"
echo "      capture time) is NOT backed up anywhere and can't be restored"
echo "      by this script - re-add it by hand (nmtui, or Wi-Fi from the"
echo "      desktop taskbar) once you know the network's password."
echo "  [ ] Set/reset the deluge web UI password - its auth file"
echo "      (~/.config/deluge/auth) is a local secret, not backed up or"
echo "      reproduced here. Log into http://<pi-ip>:8112 (default deluge"
echo "      password is 'deluge' on first run) and change it."
echo "  [ ] Copy films back onto /media/pi/Caravan/films if this is a"
echo "      genuinely new/replacement drive rather than the original"
echo "      physically reattached one."
echo "  [ ] spot-check: systemctl status minidlna deluged deluge-web"
echo "=================================================================="
