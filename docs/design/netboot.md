# Booting the Pi 4 from the network

Goal (owner, 2026-10-20): boot an image built a minute ago without writing the SD card, for fast
iteration, as the Phoenix-RTOS port does with its NFS root.

## What boots how

```
Pi firmware (EEPROM, network in BOOT_ORDER)
  DHCP + TFTP from the build host (dnsmasq, scripts/netboot-server.sh):
  start4.elf, fixup4.dat, the device tree, config.txt and u-boot.bin, from the image's FAT partition,
  u-boot.bin replaced by artifacts/uboot/u-boot-netboot.bin
U-Boot (netboot variant, scripts/build-uboot.sh)
  dhcp; tftpboot EFI/BOOT/BOOTAA64.EFI; setenv bootargs ip=<address>; bootefi
  (no DHCP answer: falls back to "bootflow scan", as the SD variant boots; not tried yet)
Haiku EFI loader
  "ip=" in its load options: adds network booting, finds a remote disk server by UDP broadcast
  (RemoteDisk over EFI SNP), reads the kernel and the boot modules from the image's BFS partition
Haiku kernel
  NetBootMethod: brings the network up on the interface with the loader's MAC address and IP,
  waits for its link; the remote_disk driver finds the server; BFS on remote_disk/0/1 is the boot
  volume, packagefs on top as usual
Host: remote_disk_server (Haiku's tool, built for Linux: scripts/build.sh remote_disk_server) serves a
copy of the image (artifacts/netboot/disk.img), read-write, made afresh by every `netboot-server.sh up`
```

Scripts: `scripts/netboot-server.sh up IMG | down | status`, `scripts/netboot-cycle.sh` (agents, under
the bench lock), `scripts/pi-test.sh --netboot IMG` (a person at the bench). The card in the Pi is
irrelevant while the server answers.

## Why a remote disk and not an NFS root

Haiku has no NFS root. The loader reads the kernel and the boot modules from a file system it has
itself (BFS, or a tar archive in the PXE case; `src/system/boot/loader/file_systems`), and the
kernel's network boot (`vfs_net_boot.cpp`) mounts a block device as the boot volume (nbd or
remote_disk), on which packagefs then mounts the system packages. The NFSv4 client (`nfs4`) works
on the Pi as an ordinary mount, after boot. The remote disk gives the same workflow: the build output
is the boot volume, nothing is copied to the card.

## What it took (2026-10-20)

- **U-Boot GENET sent nothing**: with phy-mode "rgmii-rxid" the PHY delays only the receive clock and
  U-Boot's Broadcom PHY driver turns its transmit delay off, but U-Boot also disabled the MAC's
  transmit delay (`ID_MODE_DIS`); at 1000 Mbit/s no frame reached the switch.
  `patches/u-boot/0002-net-bcmgenet-delay-transmit-clock-for-rgmii-rxid.patch`, as Linux does it.
- **Boot modules**: remote_disk, genet and the whole network stack (`build/jam/packages/Haiku`).
- **Link wait**: the kernel configured the interface while the PHY was still negotiating; the first
  request failed with "Network is down". It now waits for the link (3–4 s here).
- **remote_disk could not open partitions**: devfs opens `remote_disk/0/1` under that name, and the
  driver only knew `remote_disk/0/raw`, so no file system on a remote disk was ever identified ("did
  not find any boot partitions").
- **net_server ran DHCP** on the interface the boot volume is reached through; it now leaves an
  interface alone that already has an IPv4 address when it starts.
- **A three-way deadlock** before the desktop: `getaddrinfo()` (the Time preflet) held the
  interface's lock while the stack loaded a datalink protocol module for another domain, reading it
  from the remote disk; the remote disk's current reader waited for the interface lock. Unused boot
  modules are unloaded once the boot volume is mounted, so a network module could still come from the
  remote disk. On a network boot the kernel now keeps all network modules loaded.
- **EFI loader**: any load-option key that was not two characters long made the "ip=" search loop
  forever (only "ip=" alone worked). It also passes the netmask on now.

## Limits, follow-ups

- The netmask: U-Boot passes `ip=<address>:<server>:<gateway>:<netmask>` and the loader hands the mask
  on ("net mask", 255.255.255.0 on the bench); before, the kernel picked the classful 255.0.0.0.
- DNS and the internet: the default route goes through the gateway from `ip=` (before, it had none:
  nothing off the Pi LAN was reachable), and netboot-server.sh writes a resolv.conf into the served
  copy (NETBOOT_DNS), since net_server leaves the boot interface without DHCP. `pkgman refresh` works.
- Speed: about 60 s to the desktop: the kernel's remote disk keeps 16 requests (1 KiB each) in flight,
  the loader 8 (its part: 25 s → 5.5 s).
- The remote_disk driver is in every image now (the same image boots both ways), so an SD boot probes
  for a remote disk server too: at boot, with no network yet, the probe fails at once ("Network is
  unreachable"). With a server on the LAN, an SD-booted Pi would also show its disk. Limiting the
  driver to network boots needs a boot-method flag that outlives the kernel arguments.
