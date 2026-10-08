# Wi-Fi known-network / AP fallback for Banana Pi M2 Zero (Armbian)

Your board's onboard chip (Ampak AP6212) can only act as a Wi-Fi client
**or** an access point at any one time, not both simultaneously. This
setup uses NetworkManager to switch between the two roles automatically:

- If a Wi-Fi network you've connected to before is in range, connect to it.
- If none are in range, start a local hotspot.
- While hotspotting, periodically pause it briefly to check whether a
  known network has come back into range, and switch back if so.

## Getting this repo onto GitHub

You should have downloaded a zip of this repo. To get it onto the
board via `git clone` (much easier than copying files directly), first
push it to your own GitHub account:

1. On GitHub, create a **new empty repository** (no README/license/
   .gitignore — leave it completely empty). Note the URL it gives you,
   e.g. `https://github.com/yourname/wifi-ap-fallback.git`.
2. On your computer, extract the zip, then from inside that folder:

   ```bash
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/yourname/wifi-ap-fallback.git
   git push -u origin main
   ```

   If you don't have `git` installed locally, or don't want to use the
   command line at all: on the new repo's GitHub page, use
   **Add file → Upload files**, then drag the *contents* of the
   extracted folder in (including the `bin/` and `systemd/` folders —
   modern browsers let you drag whole folders into that box). Commit
   directly from there.
3. Make sure the repo is **private** if you're at all unsure — it will
   contain no passwords (those are typed directly on the device during
   install, never stored in the repo), but there's no reason to make it
   public either.

## Quick start: clone it on the device and run the installer

Once it's on GitHub, on the Banana Pi itself (over SSH, serial console,
or a keyboard/monitor):

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/yourname/wifi-ap-fallback.git
cd wifi-ap-fallback
sudo ./install.sh
```

It will ask you three things — your home Wi-Fi's SSID/password, a name
and password for the fallback hotspot, and a password for the web UI —
then does everything else itself: installs NetworkManager, saves your
home network *before* handing it control (to minimize any disconnect),
creates the hotspot profile, tests it, and installs + enables both
background services.

**Read the big warning it prints before typing YES.** The one real risk
in this whole setup is if you're connected over SSH via Wi-Fi and
something goes wrong mid-handover — worth having a monitor+keyboard or
serial console on hand the first time, just in case. If you're doing this
locally at the device (or don't mind briefly losing the SSH session and
reconnecting), that risk is mostly theoretical — the script pre-creates
your network's saved profile specifically to avoid it.

Run `sudo ./install.sh` again any time to redo the setup with different
answers (it's safe to re-run) — just `cd` back into the cloned folder
first (`git pull` there too, if you've since updated anything).

If you'd rather understand or do each step yourself — or `install.sh`
hits a problem — the manual steps below are the same thing broken out
individually, using the files already in this cloned repo.

## 1. Make sure NetworkManager is managing wlan0

```bash
sudo apt update
sudo apt install network-manager
sudo systemctl enable --now NetworkManager
```

Armbian sometimes leaves wlan0 under `systemd-networkd` or plain
`wpa_supplicant`. If `nmcli device status` shows wlan0 as `unmanaged`,
disable whatever else is controlling it and let NetworkManager take over:

```bash
sudo systemctl disable --now systemd-networkd wpa_supplicant@wlan0 2>/dev/null
nmcli device set wlan0 managed yes
```

If you have a `/etc/network/interfaces` entry for wlan0, remove it, and
check `/etc/NetworkManager/NetworkManager.conf` doesn't have
`unmanaged-devices=` listing wlan0.

## 2. Save your known networks

Connect to each network you want auto-connect for, once, the normal way:

```bash
sudo nmcli device wifi connect "YourSSID" password "YourPassword"
```

NetworkManager saves this as a connection profile with `autoconnect: yes`
by default — the fallback script treats every saved Wi-Fi profile (except
the Hotspot one below) as a "known network." Don't name your own network
literally `Hotspot` — that name is reserved for the fallback AP profile.

## 3. Create the hotspot profile

Pick a fallback SSID/password and create the profile once (this doesn't
start it, just defines it):

```bash
sudo nmcli connection add type wifi ifname wlan0 con-name Hotspot autoconnect no ssid "BPI-Fallback"
sudo nmcli connection modify Hotspot 802-11-wireless.mode ap 802-11-wireless.band bg
sudo nmcli connection modify Hotspot ipv4.method shared
sudo nmcli connection modify Hotspot wifi-sec.key-mgmt wpa-psk
sudo nmcli connection modify Hotspot wifi-sec.psk "ChooseAStrongPassword"
```

Test it manually before automating anything:

```bash
sudo nmcli connection up Hotspot
# check from another device that "BPI-Fallback" appears and you can join it
sudo nmcli connection down Hotspot
```

If this fails, check `journalctl -u NetworkManager -n 50` — on some
Armbian builds the AP6212 driver needs a firmware/regdomain tweak, and
the error there will point to it directly.

## 4. Install the background script

```bash
sudo install -m 755 bin/wifi-ap-fallback.sh /usr/local/bin/wifi-ap-fallback.sh
```

## 5. Install and enable the systemd timer

```bash
sudo install -m 644 systemd/wifi-ap-fallback.service /etc/systemd/system/
sudo install -m 644 systemd/wifi-ap-fallback.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wifi-ap-fallback.timer
```

Check it's running and watch its decisions:

```bash
systemctl list-timers wifi-ap-fallback.timer
journalctl -t wifi-ap-fallback -f
```

## Tuning

Edit `/usr/local/bin/wifi-ap-fallback.sh` (the installed copy — this repo's
`bin/wifi-ap-fallback.sh` is just the source you installed from):

- `RECHECK_INTERVAL` (default 300s) — how often the hotspot is briefly
  paused to check for known networks. Lower = faster recovery when you
  walk back into Wi-Fi range, but more frequent hotspot drop-outs for
  anyone connected to it at the time.
- The timer's `OnUnitActiveSec` (default 60s) controls how quickly it
  reacts after simply losing a connection (no hotspot running yet).

## 6. Web UI for adding networks (no CLI needed)

A small built-in-Python web server lets you add or forget known networks
from a browser — useful when you're out with just the hotspot and a phone.

```bash
sudo install -m 755 bin/wifi-manager.py /usr/local/bin/wifi-manager.py
sudo cp wifi-manager.conf.example /etc/wifi-manager.conf
sudo chmod 600 /etc/wifi-manager.conf
```

Edit `/etc/wifi-manager.conf` and set a real password before going further
(anyone who can reach this page can see/add/remove your saved networks):

```bash
sudo nano /etc/wifi-manager.conf
```

Then install and start the service:

```bash
sudo install -m 644 systemd/wifi-manager.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wifi-manager
```

### Using it

- **On your normal network:** browse to `http://<device-ip>:8080` and log
  in with any username and the password from the config file.
- **Via the fallback hotspot:** join `BPI-Fallback`, then browse to
  `http://10.42.0.1:8080` (NetworkManager's shared-mode hotspot uses
  `10.42.0.1` as the gateway by default — confirm with
  `nmcli connection show Hotspot | grep ipv4.address` if you've customized it).

From the page you can see the current connection state, saved networks
(with a Forget button), nearby networks found by a live scan (tap "Use" to
prefill the SSID), and a form to save + connect to a new one.

**Two things follow directly from the single-radio hardware:**

- If you add a network while connected through the hotspot, and it's in
  range, the device will switch to it — which drops the hotspot connection
  your browser is using. That's expected; it means it worked. Reconnect to
  your normal network to confirm.
- Live scanning for nearby networks doesn't work while the hotspot is
  active (the radio's busy being an AP). In that case just type the SSID
  in by hand — the form still saves and tries to connect.

### Changing the password later

Edit `/etc/wifi-manager.conf` then `sudo systemctl restart wifi-manager`.

### A note on security

This is plain HTTP with basic auth — fine for a personal device on a
trusted hotspot, but the password does travel in a lightly-obscured (not
encrypted) form. Don't reuse a password you care about elsewhere, and
don't expose port 8080 beyond your own hotspot/LAN (e.g. don't port-forward
it on a router).

## Klipper / Moonraker / Mainsail compatibility

Short version: **this won't interrupt an in-progress print**, and shouldn't
meaningfully affect Moonraker/Mainsail in normal use. Details:

- **The print itself is safe regardless of Wi-Fi state.** Klipper's host
  process (klippy) talks to the printer's MCU over USB/serial and to
  Moonraker over a local Unix socket — neither depends on wlan0 at all.
  Wi-Fi dropping, switching, or the hotspot coming up does not pause,
  cancel, or corrupt a running print.
- **Ports don't collide.** Mainsail is normally served over port 80
  (nginx) and Moonraker's API over port 7125; the web UI here defaults to
  port 8080. If you've customized those ports, just double-check they
  don't clash.
- **Built-in print-aware safety check:** the fallback script queries
  Moonraker's local API before doing its one disruptive action (briefly
  pausing an active hotspot to rescan for known networks). If Moonraker
  reports the printer is `printing` or `paused`, it skips that check for
  the cycle rather than blip the hotspot — so if you're mid-print and
  watching Mainsail over the hotspot, it won't be interrupted. If
  Moonraker isn't installed or reachable, the check is simply skipped
  (safe no-op) and everything else behaves as before. One caveat: this
  only works against Moonraker's default trusted-local-client setup. If
  you've locked down Moonraker's `[authorization]` config to require an
  API key even from 127.0.0.1, this check will silently fail closed (it
  won't detect that you're printing), and the recheck will proceed on its
  normal schedule regardless. Worth a quick check of
  `journalctl -t wifi-ap-fallback` during a test print if you've
  customized Moonraker's auth settings.
- **What can still happen:** if your normal Wi-Fi network genuinely drops
  out of range mid-print, the device will start its hotspot as designed.
  Mainsail/Moonraker are still fully usable — you'd just need to connect
  to the hotspot (`10.42.0.1`) instead of your usual LAN IP to keep
  watching or control it remotely. And if you're accessing Mainsail over
  a phone connected to the *fallback hotspot itself*, a switch back to a
  recovered home network will drop that connection (same single-radio
  limitation as everything else in this setup) — reconnect to your normal
  network to get back to it.
- **Resources:** the fallback script only runs briefly once a minute via
  a systemd timer (not a constant background process), and the web UI is
  a small pure-Python server (~10-15MB RAM) — negligible next to
  Moonraker/Mainsail's own footprint, though worth knowing on a 512MB
  board if you're already close to your memory limit.

## Notes specific to this board

- AP6212 is single-radio: client and AP modes are mutually exclusive,
  which is why the script has to tear one down before trying the other
  rather than running both at once.
- NetworkManager's `ipv4.method shared` handles DHCP/NAT for hotspot
  clients internally — you don't need a separate hostapd/dnsmasq install,
  which avoids a common conflict people hit trying to run both NM and a
  manual hostapd+dnsmasq stack on this board.

## Repo layout

```
.
├── install.sh                       # run this
├── wifi-manager.conf.example        # template for /etc/wifi-manager.conf (manual install only)
├── bin/
│   ├── wifi-ap-fallback.sh          # installed to /usr/local/bin/
│   └── wifi-manager.py              # installed to /usr/local/bin/
└── systemd/
    ├── wifi-ap-fallback.service
    ├── wifi-ap-fallback.timer
    └── wifi-manager.service         # installed to /etc/systemd/system/
```
