# WiFi: a network joined once is joined again after a reboot

Owner 2026-11-18: "join a network once in Network preferences / `ifconfig … join`, reboot, it re-joins by itself".
Branch `v2-wifi` of haiku (origin), on rpi4 2753face8e. Not merged.

## 1. How it works (and what was missing)

```
boot: net_server configures /dev/net/broadcomfmac/0 (no interface settings: auto-config)
  AutoconfigLooper (one per device) watches link + WLAN notifications
    kernel scan done → B_NETWORK_WLAN_SCANNED      (openbsd_wlan: RenkuOS #471, rpi4 fbd46ca58b)
      → kMsgAutoJoinNetwork → NetServer::_AutoJoinNetwork()
          for each entry of /boot/system/settings/network/wireless_networks seen in the scan:
            _JoinNetwork(name) → no wpa_supplicant on arm64 → the entry's "password"
              → IEEE80211_IOC_HAIKU_JOIN + IEEE80211_HAIKU_JOIN_PASSPHRASE (584742feec; the kernel derives the PMK)
    link up → B_NETWORK_DEVICE_LINK_CHANGED → DHCP
```

- **Where networks are stored:** `BNetworkSettings` keeps them in `wireless_networks` under
  `B_SYSTEM_SETTINGS_DIRECTORY` (`/boot/system/settings/network/`, not `~/config/settings`), driver-settings format,
  one `network { name …; password …; … }` block each. The `password` field exists upstream; `_JoinNetwork()` already
  reads it for a saved network.
- **What was missing:**
  1. Nothing ever wrote that file. A join (`ifconfig … join`, Network preferences, the Deskbar menu) is
     `kMsgJoinNetwork`; only `kMsgAddPersistentNetwork` stores, and nothing sends it. Upstream relies on
     wpa_supplicant, whose dialog keeps the passphrase in the keystore. We have no supplicant.
  2. The auto-join was tried once per boot: the first scan set `fJoiningNetwork` for good (a scan that missed the
     access point disabled it).
  3. **Network boots only:** the link-change notification never reached user space, so after the auto-join no DHCP
     started (associated, no address). The stack is initialised from the loader's `boot/network` modules, and the
     notifications module was not among them: "networking stack notifications could not be initialized: No such
     file or directory" in every network boot's serial log. SD boots load the stack from the disk; their logs
     (r18-sd1/sd2, mega28-check) have no such line, so they are not affected [inferred, not run].

## 2. Changes (branch `v2-wifi`)

| Commit | What |
|---|---|
| d6b719aac9 `net_server: retry auto-join after a timeout` | RenkuOS PR #472 844755ddcd unchanged (Dru Satori): a new attempt on the next scan once 30 s passed without a link; the flag cleared when a link is lost |
| 77d28ba987 `net_server: remember networks joined interactively` | RenkuOS PR #472 11e9abe4a5, **adapted** (below) |
| b689ed27d7 `build: load the network notifications module on network boots` | `<net>notifications` in the `boot/network` module links |

The adaptation of 11e9abe4a5:
- **The passphrase is stored** in the network's entry when no wpa_supplicant runs (with one, only the name, as
  upstream). Not the keystore: `keystore_server` asks the user with a window at an application's first access
  (`AppAccessRequestWindow`), which at boot would hold net_server's join. Haiku keeps the keystore unencrypted as
  well, so the settings file is no weaker.
- **Written only once the link is up** with that network (NetServer watches link changes while it has something to
  remember; the device must have a link and be associated with that SSID). A join with a wrong passphrase is never
  remembered. An existing entry is replaced only when the passphrase differs.
- **No auto-join for 30 s after a join on request** (`B_BUSY`), so a scan arriving during a manual join cannot
  replace it with a saved (possibly stale) passphrase; an auto-join drops what a failed manual join left pending, so
  that one cannot be saved later when the auto-join links.
- `kMsgGetPersistentNetwork` no longer passes the password out; the auto-join result goes to the syslog
  (`net_server: <device>: auto join network "<name>": <status>`; its standard output goes nowhere).

Not changed: devices are matched by the name in the request (`/dev/net/broadcomfmac/0` from ifconfig and the
preferences); a request naming the device differently would not get the 30 s hold-off.

## 3. Network preferences and the Deskbar menu send no passphrase

`InterfaceView` and `NetworkStatusView` call `BNetworkDevice::JoinNetwork(address)` without a password: upstream the
wpa_supplicant asks for it. Without one, a **first** WPA2 join from the preferences cannot work (the preferences
show nothing; the Deskbar menu shows "Could not join wireless network"). Once the network is saved (one
`ifconfig … join`), choosing it there works: the passphrase comes from the entry. USER-GUIDE §9.2 ("Preferences →
Network takes the same path") and HANDS-ON check 7 ("enter its password") need correcting; a passphrase prompt in
net_server (it is a `BServer` without a GUI context) or in the two clients is the missing piece. Not done here.

## 4. Test (network sessions; `scripts/wifi-autojoin.sh` + `tools/pi-tests/wifi-autojoin.sh`)

The passphrase goes to the Pi on ssh's stdin only (from local.conf, as n7-wifi.sh); the Pi side reports the saved
file as counts and names and filters every syslog line against the passphrase ("leak lines", 0 everywhere); the
host side refuses output that holds it. Reboot inside one session: `shutdown -r` (the cycle's netboot server and
the remote disk stay, so the disk survives the reboot).

Results: §5.

## 5. Results

Image: the `v2-wifi` worktree build of b689ed27d7 (`@pi-mmc`, `-sHAIKU_PI_GL=1 -sHAIKU_IMAGE_SIZE=4500`; jam rc 0,
no warnings in `src/servers/net`; the worktree build printed "png.h: No such file" for three translators with rc 0
and 11 "package … not available" lines, which do not touch networking). Bench AP: WPA2-PSK, 2.4 GHz.

| Session | What | Result |
|---|---|---|
| waj1 (release image-2026-11-18) | entry written by hand, `shutdown -r` | associated + link 5 s after the WLAN driver started, **no DHCP** (no address for minutes; `ifconfig auto-config` by hand then got one): network-boot notifications missing (§1.3) |
| waj2 (release image + new net_server started by hand) | `join` with a wrong passphrase | associated, no link, **not remembered** (no file) |
| waj3 (v2-wifi) | serial log | no "notifications could not be initialized" (every earlier network boot had it) |
| waj3 | wrong passphrase | associated, no link, not remembered |
| waj3 | `ifconfig … join` with the passphrase, **no auto-config** | link + DHCP address **7 s** after the join (before: no DHCP without `auto-config`); syslog `remembered network`; the file holds 1 entry with the passphrase |
| waj3 | wrong passphrase over the saved network | the saved passphrase kept (checked by comparison on the Pi) |
| waj3 | **`shutdown -r`, no commands** | **auto-joined, link 5 s after the driver came up, DHCP address, ping to the AP 3/3** (8–208 ms) |

| waj4 (v2-wifi, same build rebuilt) | good join, then `ifconfig down` / `up` ×3 | link back after 4, 4, 3 s each time; the kernel re-associated by itself (no auto-join line), DHCP again |
| waj4 | `shutdown -r` ×2, no commands | auto-joined both times (one "auto join … No error" per boot), address, ping 3/3; with waj3 **3 of 3 reboots** on the branch |

Passphrase checks: "leak lines" 0 in every syslog, the host wrapper found it in no output, `git diff` count 0.

**Found, not fixed:**
- After a failed join (associated, no key handshake) bwfm stays associated and does not scan, so no scan-done arrives
  and the saved network is not tried again until the interface goes down and up, or the next boot. The saved
  passphrase is not touched. (`ifconfig … scan` did not change that, 1 try.)
- After `ifconfig down` / `up` **following a wrong-passphrase join** the auto-join was sent ("auto join network …:
  No error") but bwfm went `SCAN -> INIT` and never associated within 100 s (1 of 1), and no further scan-done came to
  retry. After a good join, down/up re-links by itself (waj4, 3 of 3), so this is tied to the failed join's state. Joins after an interface
  restart have been unreliable before (f43d42c93b); not investigated further. Reboots: 2 of 2 joined (waj1, waj3).
- `ping` to the AP answered (0.3 ms) while the link was down after the wrong join; the address of the earlier lease
  stays on the interface. The test grades by the link flag and the association, not by ping.

**Not tested:** the SD-card boot (inferred unaffected, §1.3); Network preferences / the Deskbar menu (§3); a
network with a wpa_supplicant (none on arm64); the 30 s retry after a first scan that misses the AP; open networks;
the 30 s hold-off and the drop of a pending entry by an auto-join followed by a link (neither path was seen ending in
a link); SSIDs or passphrases with spaces or `" # ; ' = { } \` (the settings writer escapes them with backslashes,
`DriverSettingsMessageAdapter` `EscapeString`, and the driver-settings parser reads that back — by reading only).

**For the main session:** 77d28ba987 keeps Dru Satori as author (with his Signed-off-by) although most of its lines
are the haiku-pi adaptation; re-author it at integration if preferred. Docs to correct with the merge: USER-GUIDE §9.2
("Preferences → Network takes the same path"; "remembered across reboots is untested"), HANDS-ON check 7 (a first
WPA2 join from the preferences cannot ask for the passphrase), and image-2026-11-18's note that saved WiFi networks
are re-joined after boot (nothing wrote the entry in that image; on a network boot no DHCP followed either).
