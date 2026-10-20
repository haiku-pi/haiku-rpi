# Haiku on the Raspberry Pi 4 — network boot setup tutorial (advanced)

Boot the Pi 4 straight from an image on your build machine, without writing the SD card: the Pi loads
its boot files over the network, and Haiku reads its boot volume from the build host as a **remote
disk**. An image you built a minute ago boots at once; whatever Haiku writes goes to a fresh copy of the
image, so the build output stays untouched.

This is the development workflow of this port: most Pi tests of 2026-10-20 (Rust, vkQuake, HEVC
decoding, Firefox, Python, llama2.c, ...) ran over a network boot. It needs a second Ethernet link on the host
and more Linux networking than the [SD card path](docs/BUILD.md); you should be comfortable with
`sudo`, network interfaces and a serial console.

> **Tested on:** a Raspberry Pi 4 Model B, 4 GB, connected to a USB-Ethernet adapter on an Ubuntu 26.04
> build host, 2026-10-20/21.

---

## How the network boot works (the big picture)

```
   Raspberry Pi 4                                   Linux build host
  ┌──────────────────────┐                        ┌──────────────────────────────────────────┐
  │ EEPROM bootloader    │ 1. DHCP, TFTP          │ dnsmasq (scripts/netboot-server.sh)       │
  │ (network in          │───────────────────────▶│  DHCP 10.42.0.10–20, TFTP from            │
  │  BOOT_ORDER)         │ start4.elf, fixup4.dat,│  artifacts/netboot/tftp/ = the image's    │
  │                      │ dtb, config.txt,       │  FAT partition with u-boot-netboot.bin    │
  │ U-Boot (netboot)     │ u-boot.bin             │                                           │
  │                      │ 2. DHCP, TFTP          │                                           │
  │                      │ EFI/BOOT/BOOTAA64.EFI  │                                           │
  │ Haiku EFI loader     │ 3. remote disk (UDP)   │ remote_disk_server, UDP port 8765         │
  │ Haiku kernel         │───────────────────────▶│  serves artifacts/netboot/disk.img,       │
  │  boot volume =       │   kernel, modules,     │  a fresh copy of the image (read-write)   │
  │  remote_disk/0/1     │   the BFS volume       │                                           │
  └──────────────────────┘                        └──────────────────────────────────────────┘
          RJ45 ─────────── the host's Pi LAN interface (10.42.0.1/24) ───────────
```

1. **The Pi's firmware** (its EEPROM bootloader) asks for an address by DHCP and loads `start4.elf`,
   `fixup4.dat`, the device tree, `config.txt` and `u-boot.bin` by TFTP. The host serves the files of
   the image's own FAT partition, with one substitution: `u-boot.bin` is the **netboot variant** of
   U-Boot (`artifacts/uboot/u-boot-netboot.bin`).
2. **U-Boot** (netboot variant) takes an address by DHCP itself, loads Haiku's EFI loader
   (`EFI/BOOT/BOOTAA64.EFI`) by TFTP, and starts it with `ip=<address>:<server>:<gateway>:<netmask>` in
   its load options. Its boot command is:

   ```
   setenv autoload no; if dhcp; then if tftpboot ${kernel_addr_r} EFI/BOOT/BOOTAA64.EFI; then
   setenv bootargs ip=${ipaddr}:${serverip}:${gatewayip}:${netmask}; bootefi ${kernel_addr_r}
   ${fdtcontroladdr}; fi; fi; bootflow scan
   ```

   Without a DHCP answer it falls back to `bootflow scan`, as the SD variant boots (not tried yet).
3. **Haiku's EFI loader** sees `ip=` and boots from the network: it finds a remote disk server by UDP
   broadcast (RemoteDisk over the firmware's network interface), and reads the kernel and the boot
   modules from the image's BFS partition.
4. **The Haiku kernel** brings the network up on the interface with the loader's MAC and IP address,
   waits for the link, and its `remote_disk` driver finds the server again; BFS on `remote_disk/0/1` is
   the boot volume, with packagefs on top as on any Haiku system. On a network boot the network modules
   stay loaded (a network module read from the remote disk while the network needs it once caused a
   deadlock).
5. **On the host**, `remote_disk_server` (Haiku's own tool, built for Linux) serves
   `artifacts/netboot/disk.img`, a copy of your image made afresh by every `netboot-server.sh up`.

### Why a remote disk and not an NFS root

Haiku has no NFS root. The loader reads the kernel and the boot modules from a file system it has
itself (BFS, or a tar archive), and the kernel's network boot mounts a **block device** as the boot
volume (nbd or remote_disk), on which packagefs then mounts the system packages. The remote disk gives
the workflow an NFS root would: the build output is the boot volume and nothing is copied to the card.
Haiku's NFSv4 client works on the Pi as an ordinary mount after boot, e.g.
`mount -t nfs4 -p "10.42.0.1:/" /nfs` for an export of the host. Details and the history of the
bring-up: [docs/design/netboot.md](docs/design/netboot.md).

**The same image boots both ways.** The `remote_disk` driver and the network modules are boot modules
of every image, so the image you network-boot is the image you would write to a card.

---

## 1. Prerequisites

**Hardware**

- A Raspberry Pi 4 Model B and its power supply. A switchable power outlet is convenient (the bench
  scripts drive one), not required.
- **A dedicated wired link** between the host and the Pi: a second Ethernet interface on the host
  (a USB-Ethernet adapter works) cabled to the Pi's Ethernet port. The scripts run a DHCP server on it,
  which must be the only DHCP server on that link.
- **Recommended:** a 3.3 V USB-serial adapter on GPIO 14/15 (115200 8N1). It shows U-Boot, the loader
  and the kernel; when a network boot does not come up, it is the only way to see why.
- An HDMI monitor, or a capture card (the bench scripts can grab frames).

**Host**

- The build from [docs/BUILD.md](docs/BUILD.md): at least through
  [Step 2](docs/BUILD.md#step-2--build-haikus-jam-and-u-boot) (jam and U-Boot) and an image, normally the
  regular one (`artifacts/images/haiku-pi4-regular.img`).
- `dnsmasq` (the reference host has the `dnsmasq-base` package: the binary, no system service),
  `mtools` and `fdisk` (`sfdisk`), and `python3-serial` for the bench scripts' serial capture:

  ```sh
  sudo apt-get install -y dnsmasq-base mtools fdisk python3-serial
  ```

- `sudo`: `netboot-server.sh` starts dnsmasq with it (DHCP and TFTP use privileged ports).

---

## 2. The host's Pi LAN interface

The scripts do not configure the interface; they find it. Give it the address **`10.42.0.1/24`**, kept
by nothing else:

```sh
ip -br link                     # find the interface cabled to the Pi, e.g. eth1, or enx... for a USB adapter
```

With NetworkManager, a permanent manual address (replace `eth1` with your interface):

```sh
sudo nmcli connection add type ethernet ifname eth1 con-name pi-lan \
  ipv4.method manual ipv4.addresses 10.42.0.1/24 ipv6.method disabled
sudo nmcli connection up pi-lan
```

or, until the next reboot, `sudo ip addr add 10.42.0.1/24 dev eth1 && sudo ip link set
eth1 up`.

Keep the `10.42.0.0/24` subnet: `netboot-server.sh` hands out `10.42.0.10`–`10.42.0.20` and names the
host as the Pi's gateway, TFTP server and boot server. The host's address on it can be changed with
`PI_LAN_HOST`.

The settings for your machine go into `local.conf` in the repository root (git-ignored; every setting
can also come from the environment):

```sh
cp local.conf.example local.conf
```

| Setting | Default | Meaning |
|---|---|---|
| `PI_LAN_HOST` | `10.42.0.1` | the host's address on the Pi LAN |
| `PI_LAN_IFACE` | the interface that has `PI_LAN_HOST` | set it if the lookup finds nothing |
| `NETBOOT_DNS` | `1.1.1.1` | the DNS server DHCP offers and the served image's `resolv.conf` names |
| `PI_UART` | `/dev/ttyUSB0` | the serial console (bench scripts) |
| `PI_PLUG` | — | a program called as `$PI_PLUG on` / `$PI_PLUG off` that switches the Pi's power (bench scripts) |
| `HDMI_GRABBER` | — | an HDMI capture device (bench scripts) |
| `PI_BENCH_LOCK`, `PEER_*` | — | for a Pi shared with another project: the lock every Pi cycle holds, and the other project's netboot server, which the scripts stop and restore |

A host firewall must let in, on the Pi LAN interface: DHCP (UDP 67), TFTP (UDP 69) and the remote disk
(UDP 8765). Note that `remote_disk_server` listens on **all** of the host's interfaces and has no access
control: any machine that can reach UDP 8765 can read and write the served copy. Run it on hosts whose
other networks you trust, or block the port on them.

---

## 3. Build the network boot pieces

Three things beyond an ordinary image, from the repository root:

```sh
scripts/build-uboot.sh                  # also writes artifacts/uboot/u-boot-netboot.bin
scripts/build.sh remote_disk_server     # Haiku's remote disk server, built for the host
scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc   # the image to boot (if you have none yet)
```

`netboot-server.sh` also uses the host `bfs_shell` that every image build makes.

---

## 4. The server: `scripts/netboot-server.sh`

```sh
scripts/netboot-server.sh up artifacts/images/haiku-pi4-regular.img
scripts/netboot-server.sh status        # dnsmasq: up / disk: up
scripts/netboot-server.sh down
```

`up IMG`:

1. stops a previous instance (and, on a shared bench, the other project's netboot server);
2. copies IMG's FAT partition into `artifacts/netboot/tftp/` and puts the netboot U-Boot there as
   `u-boot.bin`;
3. copies IMG to `artifacts/netboot/disk.img` (`cp --reflink=auto`: instant on a file system with
   reflinks) and writes `nameserver $NETBOOT_DNS` into the copy's
   `/boot/system/settings/network/resolv.conf`;
4. writes `artifacts/netboot/state/dnsmasq.conf` and starts dnsmasq bound to the Pi LAN interface only:
   DHCP range `10.42.0.10`–`10.42.0.20` (12 h leases), router and TFTP server (option 66) = the host,
   DNS = `NETBOOT_DNS`, TFTP from `artifacts/netboot/tftp`, no DNS service of its own;
5. starts `remote_disk_server` on the copy.

Everything it runs logs to `artifacts/netboot/state/`: `dnsmasq.log`, `dnsmasq.leases`, `disk.log` (one
line per remote disk request). `up` checks that the server binary, the netboot U-Boot and the image
exist, and that `remote_disk_server` is still alive a second after its start.

`netboot-server.sh` does not take the bench lock itself: on a Pi shared with another project, use the
cycle scripts of [section 6](#6-boot-the-pi), which do.

---

## 5. The Pi's EEPROM boot order

The Pi 4 boots in the order its EEPROM's `BOOT_ORDER` setting gives. For a network boot, **network must
be in it**; to network-boot with a card in the slot, it must come **before the SD card**. The digits of
`BOOT_ORDER` are tried from right to left (`1` = SD card, `2` = network, `4` = USB storage, `f` =
start over): the factory default tries the card first, and a value such as `0xf12` tries the network,
then the card.

Change it with Raspberry Pi's own tools: Raspberry Pi Imager's bootloader image (*Misc utility images →
Bootloader → Network boot*), or `rpi-eeprom-config` on Raspberry Pi OS. Nothing else needs changing: the
TFTP files are served from the server's root, and the bootloader finds them there (it asks for
`<serial number>/start4.elf` first and then falls back to the root, as the dnsmasq log shows below).

With the network first, the Pi falls through to the card when no DHCP server answers; the bench Pi took
about 58 s for that (2026-10-18). Conversely, **while the server is up, such a Pi ignores its card** —
stop the server (`scripts/netboot-server.sh down`) to boot from the card.

---

## 6. Boot the Pi

### By hand (no power switch needed)

```sh
scripts/netboot-server.sh up artifacts/images/haiku-pi4-regular.img
# connect the Pi's Ethernet to the Pi LAN interface, open the serial console (e.g.
# picocom -b 115200 /dev/ttyUSB0), then power the Pi on
scripts/netboot-server.sh down          # when you are done
```

What to expect (2026-10-21, the regular image, KDEBUG level 1 kernel): **the desktop about 55 seconds
after power-on** (54.8 s, measured over 15 network boots on 2026-10-20). The serial console shows the firmware's network
boot, U-Boot's DHCP and `tftpboot`, the loader, and the kernel log with
`Mounted boot partition: /dev/disk/virtual/remote_disk/0/1`.

**Watch it on the host:**

```sh
cat artifacts/netboot/state/dnsmasq.leases            # the Pi's lease
tail -f artifacts/netboot/state/dnsmasq.log           # DHCP and TFTP
tail -f artifacts/netboot/state/disk.log              # HELLO request, READ request: offset ..., WRITE request ...
```

A normal start in `dnsmasq.log`, abridged:

```
dnsmasq-dhcp: ... sent size: 10 option: 66 tftp-server  10.42.0.1
dnsmasq-tftp: file .../tftp/b75b156a/start4.elf not found for 10.42.0.12
dnsmasq-tftp: sent .../tftp/config.txt to 10.42.0.12
dnsmasq-tftp: file .../tftp/vl805.sig not found for 10.42.0.12
dnsmasq-tftp: file .../tftp/pieeprom.sig not found for 10.42.0.12
dnsmasq-tftp: file .../tftp/recover4.elf not found for 10.42.0.12
dnsmasq-tftp: sent .../tftp/start4.elf to 10.42.0.12
dnsmasq-tftp: sent .../tftp/fixup4.dat to 10.42.0.12
dnsmasq-tftp: error 0 Early terminate received from 10.42.0.12
dnsmasq-tftp: failed sending .../tftp/config.txt to 10.42.0.12
dnsmasq-tftp: sent .../tftp/config.txt to 10.42.0.12
```

The `not found` lines (the serial-number directory, `vl805.sig`, `pieeprom.sig`, `recover4.elf`,
`recovery.elf`, `dt-blob.bin`) and the "Early terminate" / "failed sending" pairs are the firmware
probing for optional files: normal.

### With the bench scripts

On a bench with a power switch and a serial adapter configured in `local.conf`:

```sh
scripts/pi-test.sh --netboot artifacts/images/haiku-pi4-regular.img
```

for a person at the bench: it brings the server up, powers the Pi on, shows the serial console in the
terminal (logged to `artifacts/uart/`) and opens a live window from the HDMI capture card
(`--no-preview` without one); closing the window powers the Pi off and takes the server down.

```sh
scripts/netboot-cycle.sh --image artifacts/images/haiku-pi4-regular.img --secs 200 --label mytest
```

is the unattended cycle: server up, power on, capture the serial console for `--secs` seconds (or until
a line matches `--until RE`; `--fail RE` ends it as a failure; `--send SECS:TEXT` types into the
console), an HDMI frame every `--hdmi-every` seconds, then power off, server down. Logs:
`artifacts/uart/<ts>-<label>.log`, frames `artifacts/hdmi/<ts>-<label>-*.png`, and
`artifacts/uart/<ts>-<label>-disk.txt`, the remote disk's request count every 5 s (a boot whose serial
line went quiet while its disk requests go on is alive). Both scripts take the bench lock, wait for any
other Pi cycle, and restore a peer project's netboot server at the end.

---

## 7. The development loop (why it is fast)

```sh
# 1. change something in sources/haiku, then rebuild: 30–60 s after the first build
scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc
# 2. serve the new image (a fresh copy of it)
scripts/netboot-server.sh up artifacts/images/haiku-pi4-regular.img
# 3. power-cycle the Pi: the desktop ~55 s later
```

From an edited source file to the new system's desktop takes about two minutes, with no card writing
and no card swapping. The pieces that made it fast (2026-10-20/21): the kernel's remote disk keeps 16
requests in flight instead of one (desktop ~90 → 70–80 s), the loader 8 (its part 25 → 5.5 s; desktop
~60 s), and the kernel's lighter debug level (54.8 s).

Test images work the same way. Build one with `scripts/mkimage-pi4.sh` — a test tree, a boot script
that runs a test and prints to the serial console, kernel settings, a blocked driver
([BUILD.md](docs/BUILD.md#making-images-mkimage-pi4sh)) — and boot it:

```sh
scripts/mkimage-pi4.sh --out artifacts/images/haiku-pi4-test.img \
  --add-tree artifacts/gl-stack/non-packaged --bootscript tools/pi-tests/gpu-report.sh
scripts/netboot-cycle.sh --image artifacts/images/haiku-pi4-test.img --label gputest
```

Its FAT partition is served too, so `--config` lines (`config.txt`) take effect on a network boot as
on a card.

**What the Pi wrote** stays in `artifacts/netboot/disk.img` until the next `up`. Read a file from it with
`scripts/image-cat.sh` (have the test `sync` before it ends):

```sh
scripts/image-cat.sh artifacts/netboot/disk.img /boot/system/var/log/syslog
scripts/image-cat.sh artifacts/netboot/disk.img /boot/system/cache/tmp/x.txt   # Haiku's /tmp
```

---

## 8. DNS and the internet

On a network boot, `net_server` leaves the boot interface alone (a DHCP run would take its address
away for a moment, and with it the boot volume); the interface keeps the address U-Boot got. The kernel
takes the netmask and the default route through the gateway from `ip=` (the host, DHCP option 3), and
the served copy's `resolv.conf` names `NETBOOT_DNS`. With that, a network-booted Pi resolved names and
`pkgman refresh` fetched both repositories over HTTPS (2026-10-20).

For anything beyond the host, **the host must forward the Pi LAN's traffic** and translate its
addresses. One way (replace `wlp1s0` with the host's uplink interface; with `ufw`, also allow routed
traffic):

```sh
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 10.42.0.0/24 -o wlp1s0 -j MASQUERADE
```

The Pi's clock comes from NTP once the network is up (the Pi has no battery clock); HTTPS fails with
"certificate not yet valid" until then.

---

## 9. WiFi on a network-booted Pi

The image's WiFi driver (`broadcomfmac`, BCM43455 over SDIO) loads on a network boot as on an SD boot,
while the boot volume comes over Ethernet. Joins on the regular image worked 3 of 3 times (2026-10-19,
SD boots). Some of the network-boot stops described below happened inside or right before the WiFi driver's
attach, and
on 2026-10-20 a SuperTuxKart test image that stopped twice that way booted with the driver hidden. For
test images that do not need WiFi you can hide it:

```sh
scripts/mkimage-pi4.sh --out artifacts/images/haiku-pi4-test.img \
  --block-entry add-ons/kernel/drivers/dev/net/broadcomfmac \
  --block-entry add-ons/kernel/drivers/bin/broadcomfmac
```

`scripts/wifi-join-image.sh` makes a test image whose boot script joins a network given in
`local.conf` (`WIFI_SSID`, `WIFI_PSK` or `WIFI_PSK_FILE`, `WIFI_GATEWAY`); the passphrase only goes into
a temporary file and the git-ignored image.

---

## 10. Known issues

- **The network-boot wedge.** About 1 in 18 network boots on 2026-10-20 (in other counts 1 in 8 to 1 in
  45) stopped at ~54 s, while the network drivers loaded and the first-boot package processing read the
  remote disk: the serial line went quiet, the remote disk's requests stopped, the kernel debugger did
  not answer — the whole system stopped. SD boots never did. A loaded host is not required (it struck
  on a quiet host too). A kernel-stack fault that fitted it was fixed late on
  2026-10-20, and the next 16 network boots were clean, but the 17th wedged in the same phase: that fix did
  not cure it. In every captured wedge the serial output stops in the middle of a line, which points to a
  CPU stalled on a peripheral access that never completes. `netboot-cycle.sh` types the kernel debugger's break and per-CPU stack dumps into any boot that
  goes quiet for 20 s before app_server set its display mode (`--no-wedge-dump` turns it off), and records the
  disk timeline. If you hit one: power-cycle and boot again.
- **Network boot timing on a busy host.** The remote disk is served by the host; under a heavy build
  (load ~15) boots were slower, and a test that checks the desktop at a fixed time reported "failures"
  that were slow boots. Time network boots on a quiet host.
- **An SD-booted Pi probes for a remote disk server too** (the driver is in every image): with no
  network yet, the probe fails at once (`Network is unreachable`). With a server running on the LAN, an
  SD-booted Pi would also show the served disk — keep the server down while you test SD boots (the
  scripts do).
- **devfs reloads `remote_disk` on a network boot** from the boot volume, and the reloaded instance's
  server search fails (`Network is unreachable`). Harmless so far.
- An **early-boot hang** (the serial line stops after `reserve_io_interrupt_vectors`) was seen once in
  about 20 boots on 2026-10-20, on a network boot; the same image booted on the next try.
- RAM does not survive a reset on the Pi 4 (tested 2026-10-20), so there is no post-mortem of a stopped
  boot: the serial console and the disk timeline are what you get.

---

## 11. Troubleshooting

| Symptom | Check |
|---|---|
| `netboot: no .../remote_disk_server (scripts/build.sh remote_disk_server)` | build it ([section 3](#3-build-the-network-boot-pieces)) |
| `netboot: no .../u-boot-netboot.bin (scripts/build-uboot.sh)` | run `scripts/build-uboot.sh` |
| `up` fails at dnsmasq; `dnsmasq.conf` has an empty `interface=` line | no interface has `PI_LAN_HOST`: give the interface its address ([section 2](#2-the-hosts-pi-lan-interface)) or set `PI_LAN_IFACE` |
| dnsmasq does not start (the DHCP or TFTP port is in use) | another DHCP server runs on the host (a system dnsmasq, another project's netboot server): stop it; only one may answer on the Pi LAN |
| `netboot: remote_disk_server died: ...` | its last lines are printed; UDP 8765 may be taken by a `remote_disk_server` left running (`netboot-server.sh down`, or stop it by its PID) |
| No lease in `dnsmasq.leases`, nothing in `dnsmasq.log` | the Pi does not try the network: EEPROM boot order ([section 5](#5-the-pis-eeprom-boot-order)); cable, link LEDs, `ip -br link`; the firewall |
| The firmware loads its files, then nothing | U-Boot's DHCP or TFTP: watch the serial console; `EFI/BOOT/BOOTAA64.EFI` must be in `artifacts/netboot/tftp/` (it comes from the image) |
| The loader starts but finds no disk; `disk.log` has no `HELLO request` | `remote_disk_server` not running (`netboot-server.sh status`) or UDP 8765 blocked by the host firewall |
| The boot stops with `did not find any boot partitions` | the remote disk was not found or not readable: `disk.log`, the firewall; the image must come from this port's tree (older Haiku `remote_disk` could not open partitions) |
| The Pi boots its SD card instead | no DHCP answer in time: server down, wrong interface, or the boot order tries the card first |
| The Pi boots the network although you wanted the card | the server is up: `scripts/netboot-server.sh down` |
| Names do not resolve, `pkgman refresh` fails | the host does not forward/translate the Pi LAN ([section 8](#8-dns-and-the-internet)); `NETBOOT_DNS` reachable? |
| `bench: waiting for the bench lock (...)` | another Pi cycle holds `PI_BENCH_LOCK`; the scripts wait up to an hour |
| `bench: /dev/ttyUSB0 is held by: ...` | a terminal program still has the serial port open: close it before a cycle script |
| `pi-test: set PI_PLUG in local.conf` | the cycle scripts need a power switch; without one, boot [by hand](#by-hand-no-power-switch-needed) |
| The boot hangs, serial console silent | see [Known issues](#10-known-issues); on a live system, three Ctrl-] then `d` enter the kernel debugger (`threads`, `cpu N`, `bt`) |

---

The SD card path, building and the image options: [docs/BUILD.md](docs/BUILD.md). What works on the Pi,
with measurements: [docs/TRY-IT.md](docs/TRY-IT.md). The design notes for the network boot:
[docs/design/netboot.md](docs/design/netboot.md).
