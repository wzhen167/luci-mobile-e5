# LuCI Mobile

<div align="center">
  <sub><b>Rongyue E5 build</b> · fork of <a href="https://github.com/cogwheel0/luci-mobile">cogwheel0/luci-mobile</a> · arm64 APK in <a href="https://github.com/wzhen167/luci-mobile-e5/releases">Releases</a></sub>
  <br><br>

  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_01.png" alt="LuCI Mobile dashboard on Android" width="320"/>
</div>

LuCI Mobile is an open-source Flutter client for OpenWrt routers. It talks to LuCI RPC so you can check router health, inspect clients and interfaces, scan Wi-Fi networks, and handle common admin tasks from a phone. This build extends that to the vendor control plane a Rongyue E5 exposes.

## About this build

**A build tuned for the Rongyue E5** (荣悦 E5) — a Unisoc UMS9621 mobile router
running OpenWrt 25.12.5 with the `e5-mobile` kernel. It is a fork of
[cogwheel0/luci-mobile](https://github.com/cogwheel0/luci-mobile), which stays the
upstream project: everything that is not E5-specific is upstream's work, and bugs
that are not specific to this build belong in upstream's tracker, not here.

The E5 does not only speak plain LuCI. It ships its own control plane —
`mu300dash`, `e5status`, `e5-sms` — and several features only exist behind it.
This build teaches the app to use them.

## What this build adds over upstream

- **Services hub** — start, stop and restart `init.d` services and the plugin
  services, folded into Settings instead of taking a sixth bottom tab.
- **OpenClash control** — start, stop and restart the core, switch between rule,
  global and direct mode, and pick a node in any proxy group of the active config.
- **Radio control via `mu300dash`** — network mode, per-RAT LTE/NR band locks,
  cell lock, re-apply after reboot, mobile data, and radio on/off per SIM slot.
  Writes are asynchronous on the router side, so the app polls the lock job until
  the modem settles instead of pretending the change landed.
- **Telemetry from `e5status`** — signal, band, operator, dual-SIM state and
  billing-cycle usage read from the vendor object, with `modemmanager` and `mmcli`
  used only as a fallback.
- **SMS through `e5-sms`** — the vendor's own message store, falling back to
  `sms-tool` on builds that do not have it.

None of this is assumed. Every E5 surface is probed first: if the backend does not
answer, the tab or tile that depends on it disappears rather than showing controls
that cannot work. On any other OpenWrt router the app behaves exactly as upstream.

## Compatibility

| | |
| --- | --- |
| Tested on | Rongyue E5, OpenWrt 25.12.5 r33051-f5dae5ece4, kernel 6.18.54-e5-mobile4 |
| Hardware | Unisoc UMS9621 (`sprd,ums512-base`), dual SIM, front screen |
| Needs for the extra tabs | `mu300dash` for radio control, `e5status` for telemetry, `e5-sms` for the vendor SMS store |
| Without them | Those tabs are hidden; the rest of the app works as upstream |
| Build | `2.1.0+15`, arm64 release APK signed with this repo's own key and attached to each release |

## Following upstream

Upstream stays the canonical project. To pull its changes:

```sh
git fetch upstream
git merge upstream/main
```

`upstream` is already set as a remote here, and GitHub's *Sync fork* button does
the same thing.

## What it does

Everything in this list is upstream's feature set, unchanged. The E5 additions are
listed further up.

- Saves multiple router profiles and switches between them. A profile can include a fallback address for access from another network.
- Shows throughput, CPU load, memory use, uptime, wireless signal, and interface status on one dashboard.
- Lists clients for every saved router or only the selected router. Search by hostname, IP address, MAC address, or vendor.
- Shows wired and wireless interface details, traffic totals, addresses, radio state, and channel information.
- Scans nearby Wi-Fi networks and can connect a router radio as a station.
- Edits wireless networks and radios: SSID, security, channel, width and country code.
- Reserves a DHCP address for a client, or blocks one with a firewall rule.
- Wakes a sleeping device over the network.
- Manages port forwards, traffic rules, zones and static routes.
- Edits the hostname, timezone and description, and changes the router password.
- Starts, stops and restarts services, and configures SQM, adblock, UPnP and DDNS.
- Reads cellular modems: signal, operator, connection state and traffic, edits the APN, and lists and sends SMS.
- Runs ping, traceroute and nslookup from the router, and reads its system and kernel logs.
- Keeps an activity feed of what changed, and on Android can notify about it in the background.
- Shows traffic history per client where the router records it.
- Reboots a router after confirmation.
- Follows the system theme or uses a selected light or dark theme.

Where the router allows it, configuration changes go through its own
apply-with-rollback protocol: if the phone cannot confirm a change in time,
the router puts the previous configuration back by itself. Some routers do
not grant the permission that makes this work, and there the change is
committed immediately; the app says so while it is going in, rather than
letting you rely on a safety net that is not there.

Credentials and router profiles are stored through `flutter_secure_storage`. The app asks before trusting a self-signed HTTPS certificate. It does not include analytics, tracking, or advertising SDKs.

## Screenshots

| Dashboard | Login | Clients | Client details |
| --- | --- | --- | --- |
| <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_01.png" alt="Router dashboard" width="200"/> | <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_02.png" alt="Router login" width="200"/> | <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_03.png" alt="Connected clients" width="200"/> | <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_04.png" alt="Expanded client details" width="200"/> |

| Interfaces | Interface details |
| --- | --- |
| <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_05.png" alt="Router interfaces" width="200"/> | <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_06.png" alt="Expanded interface details" width="200"/> |

## Install

Download the APK from [Releases](https://github.com/wzhen167/luci-mobile-e5/releases).
It is built for arm64, which is what the E5 is, and signed with this build's own
key — so it will not install over an official LuCI Mobile. Uninstall that first,
which also clears the router profiles it stored.

To build it yourself:

```bash
git clone https://github.com/wzhen167/luci-mobile-e5.git
cd luci-mobile
flutter pub get
flutter build apk --release
```

The upstream app is on [Google Play](https://play.google.com/store/apps/details?id=com.cogwheel.LuCIMobile),
the [Apple App Store](https://apps.apple.com/app/luci-mobile/id6749455847) and
[IzzyOnDroid](https://apt.izzysoft.de/fdroid/index/apk/com.cogwheel.LuCIMobile).
That is the same app without the E5 additions described above, so none of the
vendor modem controls are there.

Useful checks:

```bash
flutter analyze
flutter test
```

## Router setup

The router must run OpenWrt with LuCI enabled. LuCI Mobile also needs the LuCI RPC and wireless information modules:

```sh
# OpenWrt using opkg
opkg update
opkg install rpcd-mod-luci rpcd-mod-iwinfo

# OpenWrt using apk
apk update
apk add rpcd-mod-luci rpcd-mod-iwinfo

/etc/init.d/rpcd restart
```

Check that the RPC object is available:

```sh
ubus list luci-rpc
ubus call luci-rpc getNetworkDevices '{}'
```

## Troubleshooting

- If the app cannot connect, open the same router address in a browser and check the scheme, port, firewall, and VPN route.
- If login fails, verify the username, password, and administrator permissions in LuCI.
- If the dashboard is empty, install the RPC modules above, restart `rpcd`, and run the two `ubus` checks.
- If login or the dashboard times out even though LuCI works in a browser, the router's LuCI may stall on parallel requests ([openwrt/luci#9091](https://github.com/openwrt/luci/issues/9091)). Limit uhttpd to one request at a time:

  ```sh
  uci set uhttpd.main.max_requests=1
  uci commit uhttpd
  /etc/init.d/uhttpd restart
  ```
- Accept a self-signed certificate only after checking that its fingerprint belongs to your router.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.

Where a report belongs:

- Something wrong with the app on any router, or with a feature that comes from
  upstream → [cogwheel0/luci-mobile/issues](https://github.com/cogwheel0/luci-mobile/issues).
- Something wrong with the E5 additions — the radio tab, the services hub,
  OpenClash control, `e5status` telemetry or `e5-sms` → [this repo's
  issues](https://github.com/wzhen167/luci-mobile-e5/issues).

## License

GPL-3.0, see [LICENSE](LICENSE). Upstream is
[cogwheel0/luci-mobile](https://github.com/cogwheel0/luci-mobile), released under
the same license; this build keeps those terms and adds no restrictions of its own.
LuCI Mobile is an independent project and is not affiliated with OpenWrt.

Thanks to the OpenWrt and Flutter communities, the project contributors and testers, and [OpenWrtManager](https://github.com/hagaygo/OpenWrtManager) for early inspiration.
