# The owner's prompts

Every prompt the project's owner wrote by hand about this port, verbatim, with the time it was sent. Nine
messages in three and a half days. The automatic ones are left out: the cron heartbeat that resumes autonomous work
("Haiku-Pi heartbeat …"), the weekly upstream-sync cron, task notifications, the context summaries the
session writes for itself, and two messages from the parallel Phoenix-RTOS session about sharing the bench.

The port, from the first prompt to the Haiku desktop on a real Raspberry Pi 4, ran on prompt 1 alone. So did
everything else up to prompt 2: USB, Ethernet, NFS, WiFi, OpenGL ES on the V3D, Quake, audio, Bluetooth,
WebPositive, packages built natively on the Pi, about 47 hours of work. The weekly logs (`docs/log/`) record
that work, step by step.

How this list was made: the session transcripts were searched for messages the owner typed. That includes
prompts typed while the agent was working, which are stored as queued commands. Times are as recorded, in UTC,
with Central European Summer Time (CEST, the lab's local time) next to them.

## 1. 2026-10-17 21:25:35 UTC (23:25 CEST): the starting point

> Our Phoniex-RTOS porting turned out to be very sucesful! We did an amazing project (and it will be continued
> in the future). But now I want to challange ourselves with something even more exciting and I want to showcase
> to full power of AI coding in this experiment. We gathered big knowladge set on Pi4 OS-development. We also
> established a very effective LAB setup allowing for autonomous testing. The Pi can be netbooted to Phoenix or
> Linux and this netboot environment can be then used to flash the SD card for future testing. We can examin
> HDMI, UART, Eth, Wifi. And we know exactly how to make an OS to work on Pi4 - including full GPU acceleration
> and multiprocess GPU access. We know how to debug early stage OS with qemu (with Pi4 profile) and gdb. We know
> how to prepare a bootable image. We know what issues we encountered in early stage Phoenix-RTOS on real Pi4
> bring-up (issues with cache, issues with boot loader, MMU, DMA, initialization...). We also know that you can
> work autonomously with amazing effects! Therefore I want you to work 100% autonomously and do a full port of
> another OS to Pi4. This time I want to work with Haiku OS. Create a fresh Haiku local checkout from official
> Git. Create a separate coordination repo for scripts, documentation, tools. Do not mention this Haiku project
> in Phoenix-RTOS Pi repos. But DO use Phoenix-RTOS Pi repos as a source of tools, knowladge, inspiration,
> skills, memories. I want you to drive Haiku to Pi4 into a fully usable state - on-par with that we have in
> Phoenix-RTOS (including GPU, Eth, Wifi, NFS, SD, basic GPIO, thermal readouts, SMP, and all other stuff we
> did). I want the system to be stable, highly performant. Remember that the host is fully avaliable to you
> including paswordless sudo. So if any package is needed host side - get it. Similarlly to Phoenix, I've
> create a new GitHub org (haiku-pi) on my GitHub account. In this org you should place the fork of the
> upstream Haiku repo + your coordination repo and push progress frequently there. For now we don't push our
> changes up-stream, but we pull incoming changes. Try to use all the Phoenix-RTOS porting learnings to
> establish as efficient working process as you can, encapsulating common tasks into scripts and skills. Setup
> cronjobs to allow fully autonomous work. Remember to consult other OSes (including our version of
> Phoenix-RTOS, Linux, BSDs and others...) when in trouble. If host side resources gets limited - try removing
> unneded cache data, temporary files, docker images from past builds etc. and compress older
> logs/screenshots etc. Let me know when you will have a testable early build of Haiku running on Pi. I know
> that you can't test keyboard and mouse without me. I wish you luck and I hope you will solved this challange
> with amazing results!

What followed from this prompt alone (headings from `docs/log/WEEK-2026-W42.md` and `WEEK-2026-W43.md`,
local time):

| When (CEST) | Milestone |
|---|---|
| 2026-10-18 02:00 | **The Haiku desktop on the real Pi 4**: SD card, U-Boot, the Haiku loader, the kernel, userland, desktop on HDMI. 2.5 hours after the prompt |
| 2026-10-18 04:00–07:15 | USB; thermal + GPIO; Ethernet + NFS; WiFi (SDIO, firmware, WPA2 join, DHCP) |
| 2026-10-18 07:25–19:00 | The GPU: the V3D powered on, running jobs, OpenGL ES 3.1, windowed OpenGL on HDMI |
| 2026-10-19 00:30–04:00 | A boot freeze root-caused and recovered; the display driver (retrace, modes, hardware cursor); Ethernet receive ×3; SD card UHS-I |
| 2026-10-19 05:10–07:55 | Quake and Quake II on the V3D; the first port built natively on Haiku arm64; the regular image; audio |
| 2026-10-19 10:30–23:40 | NetSurf and WebPositive render https://www.haiku-os.org/; Bluetooth; pkgman from our own repository; a CPU stall root-caused (an LL/SC livelock) |

## 2. 2026-10-19 20:53:25 UTC (22:53 CEST): new directives

> When it comes to hosting packages - try using GitHub Pages (use the haiku-pi org) or a plain GitHub repo with
> packages if that works. So in general - yes - publish arm64 packages. Also schedule a cron to periodically
> (once a week during the weekend) pull changes incoming from upstream and merge with our forks, so that we keep
> up with the upstream development. You can run first of such merges tonight, and next ones on weekends.
> Finally, make sure that in the scrips and files in the coordination repo there are no entries refering to
> paths on the local machine (e.g. /home/houp). The scrips need to be portable. Ale create a script for testing
> the system on the Pi by me. Remember - just as in Phoenix-RTOS case, I don't actually have a monitor
> plugged-in. I use HDMI capture device and live preview from this capture device to see the screen. We have had
> a similar script prepared for Phoenix-RTOS that would power-on the Pi, setup capture, UART logs and everything
> needed to test the system. Also note that I do still would love to have a full netboot support with rootfs
> over NFS as this is super convininet for testing and fast iterating. I saw that you delivered video decode
> playback - but as far as I understand it is a software decode. So schedule a HW accelerated video decode for
> supported codecs and integrate it with the standard video libraries. Continue with building packages for
> arm64 (porting from x86-64). It would be super if we have Firefox working!

## 3. 2026-10-19 20:54:19 UTC (22:54 CEST)

> These new directive do not invalidate any other tasks scheduled earlier - everything that was planned should
> be delivered.

## 4. 2026-10-19 20:57:29 UTC (22:57 CEST)

> If we base on a stable Mesa version (we should) then there is no need to pull Mesa.

## 5. 2026-10-19 21:16:12 UTC (23:16 CEST)

> Can you also make a nice screenshot at some point (maybe early tommorow) with a number of windows opened at the
> same time - different apps and a game, activity monitor etc. I'd like a screenshot for social media and Haiku
> dev forum publication. If possible launch an app that would show the name of CPU, or Raspberry Pi 4B, or arm64
> and number of cores and memory etc. Whatever that would act as a visual proof that this is a live build running
> on hardware not in qemu. Push this screenshot to github (coord repo). If you like you push 4-5 different
> screenshots if this is easier (no need to choose a single one). Keep up good, autonomous work as planned.

Delivered after prompts 2–5 (all within the next day, `docs/log/WEEK-2026-W43.md`): arm64 packages published on
GitHub Pages (haiku-pi.github.io/packages), the first upstream merge and the weekend cron, the portable
coordination repository, the owner's test script, network boot with the boot volume on the build host, hardware
HEVC decoding (1080p at 115 fps, bit-exact), Firefox 157 (later with WebGL and video), and the showcase
screenshots (`docs/screenshots/`). Without further prompts came Rust and SpiderMonkey for arm64 Haiku, Vulkan
(vkQuake), SuperTuxKart, OpenArena, CPython 3.14, and a long list of kernel and driver fixes.

## 6. 2026-10-20 21:38:29 UTC (23:38 CEST): this file

> Please search the chat history of this session and write down to a separate MD file in coord repo, the
> transcript of all my prompts (along with date and time) which I manually issued to you in regards to Haiku
> porting effort. I want to show how little I have prompted you - the first working delivery of Haiku on Pi was
> essentially delivered after 1 (one) initial prompt - which underlines how strong you are while working
> autonomously without my intervention. Make sure not to include prompts generated by cronjob hearbeats. Just my
> manual prompts which were hand written in the last couple of days since Haiku work started.

## 7. 2026-10-20 21:50:22 UTC (23:50 CEST): Wine, and the documentation

The message was cut off at its end as sent.

> For the future work - after you finish all other queued and planned work, I'd like you to bring Wine along with
> x86-64 / x86 emulation integrated into Wine with projects like Fex Emu or something similar. The goal is to be
> allow for running Windows x86-64 (and/or x86) binaries on Haiku on Rpi4. This includex GPU accelerated games. I
> know Pi4 is not very powerful gaming machine, so I don't expect anything big to run there. But I'd like to show
> that this is possible. Please search for some legal, free-to-use Windows binaries - both apps and games that
> would be used for testing this. I know there have been some effort to bring Wine to Haiku on x86-64 CPUs. Let's
> extend on that. Let's make Wine as complete as it can be and provide CPU emulation / translation layer. As far
> as I know, aside od Fex Emu there are few other projects that provide this. Pick the best one. Try to provide a
> complete, high-performance experience. Use most up-to-date version of Wine and other needed components, but
> don't sync to a rolling master GitHub repos - rather stick with some stable tags / releases. Don't start this
> task right now - plan and schedule it for the future when the backlog is cleared. Improve upon user facing docs
> in our coord repo. Try to replicate the quality, completenes and level of detail that we have had in
> Phoenix-RTOS porting pr

What followed: the Wine plan ([design/wine-x86.md](design/wine-x86.md), milestone H15 in [PLAN.md](PLAN.md)) and
the documentation set linked from the [README](../README.md): the tutorials, the user guide, the build guide, the
hardware matrix, the known issues, the list of the fork's changes, the bench description and the field report.

## 8. 2026-10-20 21:50:43 UTC (23:50 CEST)

> Continue the planned work

## 9. 2026-10-20 22:13:26 UTC (00:13 CEST, 10-21): test games for Wine

> When testing Wine you might wanna check https://archive.org/details/classicpcgames or similar sites. We don't
> intentd to host copies of these Windows games. We just want to test and maybe post a screenshot or short movie
> showing that it works. So you can aim for some older, highly popular windows games - for many of them there is
> at least a publically avaliable demo version (e.g. Diablo II, NFS, SimCity, Half-life, HoMM3, Portal, Warcraft,
> Starcraft, Unreal Tournament... and so on - don't need to have all of them - just some, which are known to work
> under Wine). Figure out yourself - and make sure we have something attention catching and nice.

Recorded in the Wine plan's test-program section ([design/wine-x86.md](design/wine-x86.md)).
