# Testing HiveMinds Host on CachyOS

How to check `hiveminds-host` on a real CachyOS machine (or VM), and how to try it from the Mac across the network. So far it has been tested on macOS and in an Ubuntu arm64 VM; this is the first run on CachyOS x86_64, which is what the AUR package will target.

Nothing here changes the Mac app or your real HiveMinds data. The automated checks use scratch folders and remove nothing outside them.

**Time:** about 20 minutes, plus build time. The first build fetches and compiles the network libraries: a few minutes on a normal PC, much longer if the VM emulates x86_64 on an Apple-silicon Mac.

## 1. Prepare the VM

Networking: the Mac must be able to reach the VM's IP address. A **bridged** network (the VM gets an address on your home network, like `192.168.1.x`) is best, and it's also what lets the Mac discover the host automatically. A NAT/"shared" network usually works for connecting by address, but discovery may not cross it.

In a terminal on the VM:

```sh
sudo pacman -Syu --needed base-devel git rsync python openssh avahi nss-mdns
sudo systemctl enable --now avahi-daemon sshd
ip -4 addr show | grep inet      # note the VM's address, e.g. 192.168.1.50
```

If a firewall is on (`sudo ufw status` or `sudo firewall-cmd --state`), allow the host's port and mDNS:

```sh
sudo ufw allow 7420/tcp && sudo ufw allow 5353/udp                       # ufw
# or: sudo firewall-cmd --permanent --add-port=7420/tcp --add-service=mdns && sudo firewall-cmd --reload
```

## 2. Install Swift

The prebuilt toolchain from the AUR is the simplest:

```sh
yay -S swift-bin          # or: paru -S swift-bin
swift --version           # needs 6.0 or newer
```

(If that package is unavailable, swift.org's `swiftly` installer is the alternative: https://www.swift.org/install/linux/.)

## 3. Install Claude Code and log in

Needed for the real-agent checks:

```sh
curl -fsSL https://claude.ai/install.sh | bash
claude                    # log in once, then /exit
```

## 4. Copy the source to the VM

The latest work isn't pushed to GitHub, so copy it from the Mac. On the **Mac**, in the repo:

```sh
scripts/copy-to-linux.sh you@192.168.1.50          # your VM user and address; goes to ~/HiveMinds
```

Run it again after any change on the Mac; it only sends what changed. (It needs SSH, from step 1. Without SSH, a shared folder or `git bundle` works too.)

## 5. Build and run the automated checks

On the **VM**:

```sh
cd ~/HiveMinds
swift build --product hiveminds-host        # the first time takes a while
swift test                                  # core and network tests: expect two "Test run with … passed" lines (59 and 15 tests)
scripts/test-host.sh                        # agents, Ctrl+C, SIGTERM, resume: expect "ALL 30 PASSED"
scripts/test-host.sh --real                 # the same with the real Claude Code (Haiku; costs a little): expect "ALL 27 PASSED"
sudo ip addr add 203.0.113.5/32 dev lo      # a test address outside the private ranges (gone after a reboot)
scripts/test-host-network.sh --non-private 203.0.113.5
                                            # pairing, the defences, two devices, mDNS, a non-private peer: expect "ALL 48 PASSED"
```

Then the release binary the AUR package will ship (Swift built in, so it runs without Swift installed):

```sh
swift build -c release --static-swift-stdlib --product hiveminds-host
ldd .build/release/hiveminds-host          # expect only libc, libm, libstdc++, libgcc_s (and the loader)
.build/release/hiveminds-host --version     # hiveminds-host 0.5.0
```

## 6. Try it from the Mac, across the network

This step uses the host's hidden test client, which speaks the same protocol as the app and prints every reply, so problems are easy to see. Step 6b tries the same host from the HiveMinds app.

**On the VM**, make a scratch project, trust it in Claude Code once, and start the host:

```sh
mkdir -p ~/hm-test && cd ~/hm-test && git init -q && echo "# test" > README.md && git add . && git commit -qm init
claude                     # choose "Yes, I trust this folder", then /exit
cd ~/HiveMinds
H=.build/debug/hiveminds-host
$H projects add ~/hm-test
$H serve
```

It prints its address, its fingerprint and a pairing code (press `p` for a new one; each lasts 60 s).

**On the Mac**, in the repo:

```sh
export SDKROOT=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk | sort -V | tail -1)
swift build --product hiveminds-host
H="$(swift build --show-bin-path)/hiveminds-host"
VM=192.168.1.50                               # the VM's address

dns-sd -B _hiveminds._tcp                     # discovery: a "hiveminds-…" line should appear (Ctrl+C to stop)
$H debug remote $VM pair 123456 --name "Ethan's Mac"   # the code shown on the VM; then press y on the VM
$H debug remote $VM projects                  # hm-test
$H debug remote $VM create hm-test --task "Create hello.txt containing hi. Nothing else." --model haiku --own-branch
$H debug remote $VM agents                    # watch it go working → done
$H debug remote $VM attach <first 8 of the id> --seconds 5    # prints the agent's screen, rebuilt on the Mac
$H debug remote $VM changes <id>              # hello.txt, from the agent's branch
```

Things to check, by hand:

- **The owner's yes:** on the VM, the pairing question names "Ethan's Mac" and its fingerprint. Try `n` once: `$H debug remote $VM pair <new code> --name Other --fresh` (a throwaway identity); it must say `notAllowed`.
- **Two devices on one agent:** a second device is a second identity, kept in its own folder. Define `B() { XDG_STATE_HOME=/tmp/device-b "$H" debug remote $VM "$@" --name "Device B"; }`, pair it (`B pair <code>`, `y` on the VM), then in two Mac terminals run `$H debug remote $VM attach <id> --seconds 30` and `B attach <id> --seconds 30`. In a third: `$H debug remote $VM take <id> --type "say hi" --seconds 20`; meanwhile `B type <id> hello` must be refused with "Ethan's Mac is typing"; `B take <id>` takes over, and both watchers print who took over.
- **Revoke:** on the VM, in a second terminal, `hiveminds-host devices list`, then `hiveminds-host devices revoke "Ethan's Mac"`. A Mac `attach` running at that moment ends; `hello` afterwards says `PAIRING-REQUIRED unknownToken`.
- **The audit log:** `hiveminds-host log` on the VM shows the pairing, sign-ins, the agent you created, the take-over, the revoke.
- **Stopping:** Ctrl+C on the VM with the agent running asks first; `y` stops it, and an attached Mac client prints `HOST-STOPPING`.
- **A host without a terminal:** `hiveminds-host serve > /tmp/host.log 2>&1 &`, then pair with codes from `hiveminds-host pair` in another terminal.

## 6b. Try it from the HiveMinds app

With `serve` running on the VM (step 6) and the latest build of HiveMinds on the Mac:

1. **Find it:** with Settings > Hosts > "Look for hosts on this network" on, the sidebar shows "On this network" with the host's address. If it doesn't appear (a VM on a NAT network can't announce to the Mac), use Settings > Hosts > Pair by Address… with the VM's address.
2. **Pair:** press Pair…, compare the fingerprint in the sheet with the one `serve` printed, type the code, then press `y` on the VM. The host appears in the sidebar under This Mac with a green dot and its projects.
3. **An agent:** New Agent in `hm-test` (the sheet says "Runs on <host>"), Haiku, a small task. Its tab has a server icon; the header shows the host's name. The terminal shows the agent's screen; type into it.
4. **Team use:** with the test client from step 6 also attached (`$H debug remote $VM take <id> --seconds 60`), the header says "Ethan's Mac is typing" (the client's name) with Take Over. Allow/Don't Allow on a prompt is refused until you take over; then it works and the client prints who took over.
5. **Plan mode:** a new agent with "Plan first" on; approve its plan from the tile or the Overview card. It should carry on in the chosen review mode.
6. **Quit and come back:** quit HiveMinds; on the VM `hiveminds-host status` still lists the agent. Reopen: it's there again with its screen.
7. **Changes and History:** the agent's Changes come from the VM. Delete it; History shows it under "Deleted on <host>".
8. **Stopping the host:** Ctrl+C on the VM (then `y`). The sidebar shows "<host> was stopped" and the tiles say so. Start it again: the app reconnects by itself within a minute (sooner if discovery sees it).
9. **Forget:** the host's … menu > Forget. It disappears from the sidebar; the agents keep running on the VM.

## 6c. Install the real package

This is the check for the AUR package, before anything is published. On the **Mac**, `scripts/build-host-x86_64.sh` makes `build/hiveminds-host-<version>-linux-x86_64.tar.gz`; then copy the package files and the tarball to the VM:

```sh
scp -r packaging/aur/hiveminds-host-bin you@192.168.1.50:
scp build/hiveminds-host-0.5.0-linux-x86_64.tar.gz you@192.168.1.50:hiveminds-host-bin/hiveminds-host-bin-0.5.0.tar.gz
```

On the **VM** (stop any `serve` from step 6 first):

```sh
cd ~/hiveminds-host-bin && makepkg -si                    # uses the tarball you copied; prints the setup steps
hiveminds-host projects add ~/hm-test
systemctl --user enable --now hiveminds-host
sudo systemctl enable --now avahi-daemon                  # so the Mac can find it
sudo ufw allow 7420/tcp; sudo ufw allow 5353/udp          # only if the firewall is on
hiveminds-host pair                                       # shows a code, then asks y/N when a device pairs
```

Then pair from the app and run an agent (step 6b). `journalctl --user -u hiveminds-host` shows the host's output. Reboot with `sudo loginctl enable-linger $USER` set: the host should be back without logging in.

## 7. Optional: the phase 0 spike

```sh
cd ~/HiveMinds/spikes/host-phase0
swift build && .build/debug/Spike selftest ~/.local/bin/claude      # expect "ALL PASSED"
```

## What to send back

Paste the last lines of each check in step 5 (the PASS/FAIL summary and any FAIL lines), anything in steps 6 and 6b that looked wrong (a screenshot helps for the app), and `uname -a` and `swift --version`. With a failure, the full output of that one command helps most.

## If something goes wrong

- **The build fails fetching packages:** check the VM has internet access; `swift package resolve` retries the download.
- **`test-host-network.sh` can't see the mDNS record:** check `systemctl status avahi-daemon`; the other checks still run.
- **The Mac can't connect (`cantConnect`):** the VM's firewall, or a NAT network the Mac can't reach. `ping` the VM from the Mac, and check `hiveminds-host status` on the VM lists that address.
- **The host isn't discovered but connecting by address works:** mDNS doesn't cross NAT networks; use a bridged network.
- **`identityChanged` on the Mac:** the host was set up again (its key is in `~/.local/share/hiveminds-host/identity/`). Pair again with `--no-pin`, or remove `~/.local/state/hiveminds-host/test-client/hosts.json` on the Mac.
- **Leftovers:** every check uses its own temporary folder. A host you started by hand stops with Ctrl+C; its settings live in `~/.config/hiveminds-host`, `~/.local/share/hiveminds-host` and `~/.local/state/hiveminds-host`, which you can delete to start fresh.
