# Pi 4 netboot test cycle

Replaces the SD-card flash loop with a fully automated cycle. The
DHCP+TFTP server runs **inside the phoenix-dev Lima VM**; the host's
`en7` USB-C ethernet is bridged into the VM by `socket_vmnet`, so macOS
itself never binds DHCP/TFTP ports and the build artifacts are served
directly from the buildroot — no copy step.

```
Pi 4 RJ45 ── [switch] ── en7 (USB-C, host) ══bridged══> lima1 (VM) ── dnsmasq ── tftp
                                                                                  |
                                                                                  v
                                                   /home/.../rpi4b-bootfs/ (live build)
```

**Recommended cabling: put an unmanaged ethernet switch between the Pi
and the Mac**, even though a crossover cable also works electrically.
With a direct cable, the host's `en7` link state mirrors the Pi's PHY
state — every `pi_power_off`/`pi_power_on` cycle toggles `en7` between
`active` and `inactive`. That toggle wedges `socket_vmnet`'s BPF capture
on a non-trivial fraction of cycles, requiring a full VM restart to
recover (see "Bridge wedge & auto-recovery" below). A switch keeps
`en7` continuously `active` regardless of Pi power state, eliminating
the most frequent wedge trigger; the only remaining trigger is
unplugging the USB-C ethernet adapter itself (e.g. undocking the
laptop), and the auto-recovery handles that.

1. macOS host runs **socket_vmnet** as a launchd-free helper that bridges
   `en7` into the VM. No daemons on the host listen for the Pi.
2. The Pi 4 is powered on via the **smart plug** (`pi_power_on.sh`).
3. The EEPROM bootloader reaches the Network mode in `BOOT_ORDER=0xf241`,
   pulls `start4.elf` and friends from the in-VM TFTP, runs Phoenix.
4. `capture-rpi4b-uart.sh` records UART for the configured window.
5. The Pi is powered off (`pi_power_off.sh`).

## Prerequisites

- One-time EEPROM update on the Pi: see
  [pi-eeprom-netboot-prep.md](pi-eeprom-netboot-prep.md).
- `socket_vmnet` installed from source into `/opt/socket_vmnet/` (Lima
  rejects Homebrew installs because they live in user-writable paths).
  Quick recipe:
  ```sh
  git clone --depth=1 -b v1.2.2 https://github.com/lima-vm/socket_vmnet.git
  cd socket_vmnet
  sudo --preserve-env=PATH make PREFIX=/opt/socket_vmnet install.bin
  ```
- A `bridged_en7` entry in `~/.lima/_config/networks.yaml`:
  ```yaml
  bridged_en7:
    mode: bridged
    interface: en7
  ```
- Lima sudoers regenerated and installed:
  ```sh
  limactl sudoers | sudo tee /etc/sudoers.d/lima >/dev/null
  sudo chmod 0644 /etc/sudoers.d/lima
  ```
  (0644 not 0440 — Lima needs to read it as the user at start-time;
  sudo only requires it not be world-writable.)
- The phoenix-dev VM's `lima.yaml` must include the bridged network:
  ```yaml
  networks:
  - vzNAT: true
  - lima: bridged_en7
  ```
  After editing, `limactl stop phoenix-dev && limactl start phoenix-dev`.
- Inside the VM: `dnsmasq` installed (one-time
  `sudo apt-get install -y dnsmasq`, with the systemd unit disabled —
  we run it ad-hoc), and a netplan override pinning `lima1` to
  `10.42.0.1/24` so the VM doesn't try to DHCP from itself.
- USB-UART cable connected; smart-plug controlling Pi power.
- `en7` connected only to the Pi's RJ45 port (no other devices).
- Pi's microSD slot **empty** (so the EEPROM falls SD → USB → Network).

## Pieces

| Script | Role |
|--------|------|
| [scripts/netboot-server-up.sh](../../scripts/netboot-server-up.sh) | Start dnsmasq inside the VM (idempotent) |
| [scripts/netboot-server-down.sh](../../scripts/netboot-server-down.sh) | Stop the in-VM dnsmasq |
| [scripts/vm-netboot-server.sh](../scripts/vm-netboot-server.sh) | In-guest worker — invoked by the host wrappers via `limactl shell` |
| [scripts/netboot-bridge-recover.sh](../scripts/netboot-bridge-recover.sh) | Restart the VM to rebuild the en7→lima1 bridge after a wedge |
| [scripts/test-cycle-netboot.sh](../../scripts/test-cycle-netboot.sh) | One full power-cycle + UART capture (with bridge auto-recovery) |
| [scripts/sync-netboot-tree.sh](../../scripts/sync-netboot-tree.sh) | Deprecated no-op (kept for back-compat) |

State directory: `artifacts/netboot/` (host path; visible inside the VM
because `~` is virtiofs-mounted, so dnsmasq writes the log/lease/pid
files where the host can read them).

- `dnsmasq.conf` `dnsmasq.log` `dnsmasq.pid` `dnsmasq.leases`
- (no `tftproot/` — TFTP serves directly from
  `_boot/aarch64a72-generic-rpi4b/rpi4b-bootfs/` in the VM.)

## Default network

| Setting | Default | Override env var |
|---------|---------|------------------|
| Iface (in VM) | `lima1` | `RPI4B_NETBOOT_IFACE` |
| Host IP | `10.42.0.1/24` | `RPI4B_NETBOOT_HOST_IP`, `RPI4B_NETBOOT_NETMASK` |
| DHCP range | `10.42.0.10–10.42.0.20` | `RPI4B_NETBOOT_DHCP_LO`, `RPI4B_NETBOOT_DHCP_HI` |
| TFTP root | `$buildroot/_boot/aarch64a72-generic-rpi4b/rpi4b-bootfs` | `RPI4B_NETBOOT_TFTPROOT` |
| State dir | `artifacts/netboot/` | `RPI4B_NETBOOT_STATE_DIR` |

## Usage

```sh
# Once per VM session (idempotent — safe to run repeatedly):
./scripts/netboot-server-up.sh

# After every code change:
./scripts/rebuild-rpi4b-fast.sh
./scripts/test-cycle-netboot.sh --label probe
# → artifacts/rpi4b-uart/rpi4b-uart-YYYYMMDD-HHMMSS-netboot-probe.log
```

The cycle script handles power-off + power-on + UART capture + power-off
in one call. Override `--capture-secs` if Phoenix needs longer than 90 s.

To stop the server:

```sh
./scripts/netboot-server-down.sh
```

## Verifying the server side

```sh
# Status from the host:
limactl shell phoenix-dev -- /Users/witoldbolt/phoenix-rpi/scripts/vm-netboot-server.sh status

# Tail the live log (writes to a host-mounted path, so this works
# from the macOS shell directly):
tail -f artifacts/netboot/dnsmasq.log

# Inspect the served tree (in the VM but path is shared with host):
ls -la /home/witoldbolt.guest/phoenix-buildroots/phoenix-rtos-project-copy/_boot/aarch64a72-generic-rpi4b/rpi4b-bootfs/
# (or limactl shell phoenix-dev -- ls -la <path>)
```

A successful Pi 4 netboot logs to `dnsmasq.log` something like:

```
DHCPDISCOVER(lima1) dc:a6:32:3c:dd:f1
DHCPOFFER(lima1) 10.42.0.10 dc:a6:32:3c:dd:f1
DHCPREQUEST(lima1) 10.42.0.10 dc:a6:32:3c:dd:f1
DHCPACK(lima1) 10.42.0.10 dc:a6:32:3c:dd:f1
sent ... start4.elf to 10.42.0.10
sent ... fixup4.dat to 10.42.0.10
sent ... config.txt to 10.42.0.10
sent ... bcm2711-rpi-4-b.dtb to 10.42.0.10
sent ... kernel8.img to 10.42.0.10
sent ... loader.disk to 10.42.0.10
sent ... phoenix-armstub8-rpi4.bin to 10.42.0.10
sent ... overlays/miniuart-bt.dtbo to 10.42.0.10
```

## Troubleshooting

- **`VM "phoenix-dev" is not running`** — start it with
  `limactl start phoenix-dev`.
- **`iface lima1 not present in VM`** — bridged network not attached.
  Confirm `~/.lima/phoenix-dev/lima.yaml` lists `lima: bridged_en7` and
  restart the VM.
- **dnsmasq fails to bind port 67/69 (in VM)** — usually a stale
  instance from a prior `up`. The script kills its own pid file at
  start; if a foreign dnsmasq is running, find it with
  `limactl shell phoenix-dev -- pgrep -a dnsmasq`.
- **Pi reaches `Boot mode: NETWORK` but never gets a lease** — cable
  not on `en7`, or the bridge isn't forwarding. Check on the host:
  `ifconfig en7 | grep status` (should be `active`); inside the VM:
  `tcpdump -i lima1 -n port 67 or port 68` will show DHCPDISCOVER if
  bridging works. If you see DISCOVER but no OFFER, dnsmasq isn't
  bound — check `dnsmasq.log`. If you see **no DISCOVER** despite the
  Pi clearly trying to netboot, the bridge has wedged — see below.

### Bridge wedge & auto-recovery

`socket_vmnet` bridges `en7` into the VM via a BPF capture on the host.
That capture goes stale across two events:

1. **Host USB-C ethernet adapter unplugged/replugged** (e.g. undocking
   the laptop from a USB-C hub). The interface re-appears as `en7`,
   `ifconfig` shows `status: active`, but no frames cross into `lima1`.
2. **Direct-crossover topology only:** `en7` link toggling from
   `inactive` to `active` when the Pi is power-cycled. With a switch in
   between this never happens (the switch is the persistent link
   partner); with a crossover it happens on every test cycle and
   intermittently wedges the bridge.

`test-cycle-netboot.sh` defends against this with a DHCP watchdog: after
power-on it tails `dnsmasq.log` for the Pi's `DHCPDISCOVER` for
`RPI4B_DHCP_WAIT_SECS` (default 25 s). On timeout it invokes
`netboot-bridge-recover.sh`, which stops dnsmasq, restarts the VM
(re-creating the socket_vmnet BPF capture), and starts dnsmasq again.

The recovery deliberately **does not power-cycle the Pi** during the
restart: keeping the Pi on means `en7` stays `active`, and a fresh
`socket_vmnet` that comes up against an active link captures cleanly.
A `socket_vmnet` started against an inactive `en7` wedges again as
soon as the link returns.

After a successful recovery the test cycle continues normally and the
trap still powers the Pi off at the end. Manual recovery if needed:

```sh
./scripts/netboot-bridge-recover.sh
```
- **Pi gets a lease but TFTP fails** — `dnsmasq.log` will show TFTP
  errors. Almost always: build hasn't run yet (empty buildroot bootfs
  dir), or wrong `RPI4B_NETBOOT_TFTPROOT` override.
- **Capture returns empty** — USB-UART unplugged, or capture started
  before the Pi powered on. `test-cycle-netboot.sh` powers the Pi on
  before starting capture, so this should be rare; if it happens,
  increase `--capture-secs`.
