#!/usr/bin/env python3
"""
wifi-manager.py

Minimal web UI (standard library only) for adding/removing known Wi-Fi
networks on a NetworkManager-managed device, so it can be done from a
phone browser instead of the command line. Designed to be reachable both
over your normal network and over the wifi-ap-fallback hotspot.

Config file: /etc/wifi-manager.conf
    PORT=8080
    PASSWORD=changeme
"""

import base64
import hmac
import html
import os
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

IFACE = "wlan0"
HOTSPOT_CON = "Hotspot"
CONFIG_FILE = "/etc/wifi-manager.conf"

DEFAULT_PORT = 8080
DEFAULT_PASSWORD = "changeme"


def load_config():
    port = DEFAULT_PORT
    password = DEFAULT_PASSWORD
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                key, val = key.strip(), val.strip()
                if key == "PORT":
                    try:
                        port = int(val)
                    except ValueError:
                        print(f"wifi-manager: invalid PORT '{val}' in {CONFIG_FILE}, using default {DEFAULT_PORT}")
                elif key == "PASSWORD":
                    password = val
    return port, password


PORT, PASSWORD = load_config()


def run_nmcli(args, timeout=25):
    """Run nmcli with args (list of strings), return (ok, output)."""
    try:
        result = subprocess.run(
            ["nmcli"] + args,
            capture_output=True, text=True, timeout=timeout,
        )
        ok = result.returncode == 0
        output = (result.stdout or "") + (result.stderr or "")
        return ok, output.strip()
    except subprocess.TimeoutExpired:
        return False, "nmcli timed out"
    except FileNotFoundError:
        return False, "nmcli not found on this system"


def get_status():
    ok, out = run_nmcli(["-t", "-f", "DEVICE,STATE,CONNECTION", "device", "status"])
    if not ok:
        return "unknown", "unknown"
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) >= 3 and parts[0] == IFACE:
            return parts[1], parts[2]
    return "unknown", "unknown"


def get_known_networks():
    """Saved wifi connection profiles, excluding the hotspot profile."""
    ok, out = run_nmcli(["-t", "-f", "NAME,TYPE", "connection", "show"])
    if not ok:
        return []
    names = []
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) >= 2 and parts[1] == "802-11-wireless" and parts[0] != HOTSPOT_CON:
            names.append(parts[0])
    return names


def get_visible_networks():
    """Scan for nearby SSIDs. May be empty/unreliable while hotspot is active
    (single-radio hardware can't scan while it's also being an AP)."""
    ok, out = run_nmcli(
        ["-t", "-f", "SSID,SIGNAL", "device", "wifi", "list", "--rescan", "yes", "ifname", IFACE]
    )
    if not ok:
        return []
    seen = {}
    for line in out.splitlines():
        parts = line.rsplit(":", 1)
        if len(parts) != 2:
            continue
        ssid, signal = parts[0], parts[1]
        if not ssid or ssid == HOTSPOT_CON:
            continue
        try:
            signal_val = int(signal)
        except ValueError:
            signal_val = 0
        if ssid not in seen or signal_val > seen[ssid]:
            seen[ssid] = signal_val
    return sorted(seen.items(), key=lambda kv: kv[1], reverse=True)


def add_network_async(ssid, password):
    """Save the profile immediately, then try to connect after a short
    delay in the background (so the HTTP response can be sent first,
    since connecting may drop the very hotspot the browser is using)."""
    if password:
        ok, out = run_nmcli([
            "device", "wifi", "connect", ssid,
            "password", password, "ifname", IFACE,
        ])
    else:
        # Open network: create profile without security, then bring it up.
        ok, out = run_nmcli([
            "connection", "add", "type", "wifi", "ifname", IFACE,
            "con-name", ssid, "ssid", ssid,
        ])
        if ok:
            time.sleep(1)
            run_nmcli(["connection", "up", ssid, "ifname", IFACE])
    return ok, out


PAGE_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Wi-Fi Manager</title>
<style>
  body {{ font-family: -apple-system, sans-serif; max-width: 480px; margin: 0 auto; padding: 16px; background: #f5f5f7; }}
  h1 {{ font-size: 1.3em; }}
  .card {{ background: white; border-radius: 10px; padding: 14px 16px; margin-bottom: 14px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }}
  .status {{ font-size: 0.95em; color: #333; }}
  .status b {{ color: #000; }}
  ul {{ list-style: none; padding: 0; margin: 0; }}
  li {{ display: flex; justify-content: space-between; align-items: center; padding: 8px 0; border-bottom: 1px solid #eee; }}
  li:last-child {{ border-bottom: none; }}
  button, input[type=submit] {{ background: #007aff; color: white; border: none; border-radius: 6px; padding: 8px 12px; font-size: 0.9em; }}
  button.danger {{ background: #ff3b30; }}
  button.ghost {{ background: #eee; color: #333; }}
  input[type=text], input[type=password] {{ width: 100%; box-sizing: border-box; padding: 8px; margin: 6px 0 12px 0; border: 1px solid #ccc; border-radius: 6px; }}
  .msg {{ background: #fff3cd; padding: 10px 12px; border-radius: 8px; margin-bottom: 14px; font-size: 0.9em; }}
  .muted {{ color: #888; font-size: 0.85em; }}
  form.inline {{ margin: 0; }}
</style>
</head>
<body>
<h1>Wi-Fi Manager</h1>
{message}
<div class="card status">
  Interface state: <b>{state}</b><br>
  Active connection: <b>{active}</b>
</div>

<div class="card">
  <h3>Known networks</h3>
  {known_list}
</div>

<div class="card">
  <h3>Add a network</h3>
  <form method="POST" action="/add">
    <label>SSID</label>
    <input type="text" name="ssid" required list="visible-ssids" value="{prefill}">
    <datalist id="visible-ssids">
      {ssid_options}
    </datalist>
    <label>Password (leave blank for open network)</label>
    <input type="password" name="password">
    <input type="submit" value="Save &amp; Connect">
  </form>
  <p class="muted">{scan_note}</p>
</div>

<div class="card">
  <h3>Networks in range</h3>
  {visible_list}
  <form method="GET" action="/"><button class="ghost" type="submit">Rescan</button></form>
</div>

</body>
</html>
"""


def render_page(message="", prefill=""):
    state, active = get_status()
    known = get_known_networks()
    visible = get_visible_networks()

    if known:
        known_list = "<ul>" + "".join(
            f'<li>{html.escape(name)}'
            f'<form class="inline" method="POST" action="/forget">'
            f'<input type="hidden" name="name" value="{html.escape(name)}">'
            f'<button class="danger" type="submit">Forget</button></form></li>'
            for name in known
        ) + "</ul>"
    else:
        known_list = "<p class='muted'>No saved networks yet.</p>"

    if visible:
        visible_list = "<ul>" + "".join(
            f'<li>{html.escape(ssid)} <span class="muted">{signal}%</span>'
            f'<form class="inline" method="GET" action="/">'
            f'<input type="hidden" name="prefill" value="{html.escape(ssid)}">'
            f'<button class="ghost" type="submit">Use</button></form></li>'
            for ssid, signal in visible
        ) + "</ul>"
        scan_note = ""
    else:
        visible_list = "<p class='muted'>No networks found.</p>"
        scan_note = (
            "If the device is currently running its own hotspot, live scanning "
            "isn't available (single Wi-Fi radio). You can still type an SSID "
            "manually above."
        )

    return PAGE_TEMPLATE.format(
        message=f'<div class="msg">{html.escape(message)}</div>' if message else "",
        state=html.escape(state),
        active=html.escape(active) if active and active != "--" else "none",
        known_list=known_list,
        visible_list=visible_list,
        ssid_options="",
        prefill=html.escape(prefill),
        scan_note=scan_note,
    )


class Handler(BaseHTTPRequestHandler):
    server_version = "WifiManager/1.0"

    def _check_auth(self):
        auth = self.headers.get("Authorization")
        if not auth or not auth.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(auth[6:]).decode("utf-8")
        except Exception:
            return False
        _, _, supplied = decoded.partition(":")
        return hmac.compare_digest(supplied, PASSWORD)

    def _require_auth(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Wi-Fi Manager"')
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Authentication required")

    def _send_html(self, body, code=200):
        encoded = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _redirect(self, location):
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def do_GET(self):
        if not self._check_auth():
            self._require_auth()
            return
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/":
            self.send_response(404)
            self.end_headers()
            return
        qs = urllib.parse.parse_qs(parsed.query)
        message = qs.get("msg", [""])[0]
        prefill = qs.get("prefill", [""])[0]
        page = render_page(message=message, prefill=prefill)
        self._send_html(page)

    def do_POST(self):
        if not self._check_auth():
            self._require_auth()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        fields = urllib.parse.parse_qs(body)

        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/add":
            ssid = fields.get("ssid", [""])[0].strip()
            password = fields.get("password", [""])[0]
            if not ssid:
                self._redirect("/?msg=" + urllib.parse.quote("SSID is required"))
                return

            def worker():
                add_network_async(ssid, password)

            threading.Thread(target=worker, daemon=True).start()
            msg = (
                f"Saving '{ssid}' and attempting to connect. "
                "If you're on the hotspot right now, you may lose this "
                "connection momentarily if it succeeds."
            )
            self._redirect("/?msg=" + urllib.parse.quote(msg))
            return

        if parsed.path == "/forget":
            name = fields.get("name", [""])[0]
            if name:
                run_nmcli(["connection", "delete", name])
            self._redirect("/?msg=" + urllib.parse.quote(f"Forgot '{name}'"))
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):
        # Keep default logging but route through syslog-friendly stdout
        print("wifi-manager:", format % args)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"wifi-manager listening on 0.0.0.0:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
