# VM Logging

This document explains how guest console logging for `nix run .#run-vm` is implemented today.

The current implementation writes the guest's serial console to a log file on the host:

- default path: `./run-vm.console.log`
- override: `RUN_VM_CONSOLE_LOG=/path/to/file.log`

## What Is Logged

The log contains output that reaches the VM's first serial port:

- UEFI firmware messages
- EFI stub messages
- Linux kernel messages sent to `ttyS0`
- initrd and systemd status output that goes to the serial console
- the serial login prompt

In a successful boot, the log reaches all the way to the guest login prompt.

## What Is Not Logged

This does not capture the exact contents of the graphical QEMU window on `tty1`.

In particular:

- framebuffer graphics are not captured
- text written only to Linux virtual console `tty1` is not captured unless it is also emitted to the serial console

So `run-vm.console.log` should be understood as a serial-console log, not a screenshot or transcript of the graphical display.

## Why QEMU Logging Alone Is Not Enough

The VM boots from the disk image's Unified Kernel Image (`UKI`) on the EFI System Partition, not from a direct kernel command line passed by QEMU.

That matters because enabling serial-console logging requires two separate pieces:

1. QEMU must expose a serial device and connect it to a host file.
2. The guest must actually use that serial device as a console during boot.

Step 1 is handled in the `run-vm` wrapper. Step 2 must be handled inside the booted image, because the effective kernel command line comes from the UKI embedded in the image.

## Runtime Flow

When `nix run .#run-vm` is started, the flow is:

1. `vmWithWritableDisk` creates a writable QCOW2 disk from `system.build.finalImage`.
2. During that preparation step, the raw image's payload UKI is rebuilt with additional kernel command-line parameters.
3. The `run-vm` wrapper creates a temporary raw serial log and starts a background sanitizer.
4. The wrapper truncates `run-vm.console.log`.
5. QEMU writes raw serial output to the temporary log file.
6. The sanitizer follows that raw log and appends a cleaned stream to `run-vm.console.log`.
7. On exit, the wrapper runs one final full sanitize pass so the saved file is complete and terminal-safe.

The relevant wrapper code is in [modules/vm.nix](/home/hrosten/projects/nixos-android-builder-fork/modules/vm.nix#L55) and [modules/vm.nix](/home/hrosten/projects/nixos-android-builder-fork/modules/vm.nix#L108).

## Kernel Command-Line Changes

Before the VM boots, `prepareWritableDisk` appends the following parameters to the image's payload UKI:

```text
systemd.show_status=true
rd.systemd.show_status=true
systemd.log_level=info
console=tty0
console=ttyS0,115200
loglevel=7
panic=1
boot.panic_on_fail
```

These do the following:

- `console=ttyS0,115200` enables the serial console used by the host log file
- `console=tty0` keeps the normal graphical/virtual-console path enabled
- `systemd.show_status=true` and `rd.systemd.show_status=true` make boot status lines visible
- `systemd.log_level=info` and `loglevel=7` make systemd and kernel boot output verbose enough to be useful
- `panic=1` and `boot.panic_on_fail` keep failures visible and fail fast during automated runs

The original image already contains `console=tty1`. Appending `console=ttyS0,115200` adds the serial console without removing the existing local console.

## How The UKI Is Updated

The helper command is `configure-disk-image append-cmdline`, implemented in [packages/disk-installer/configure-disk-image.py](/home/hrosten/projects/nixos-android-builder-fork/packages/disk-installer/configure-disk-image.py#L245).

The important detail is that the UKI is not modified in place by changing the PE section directly. Instead, the helper now:

1. extracts `EFI/BOOT/BOOTX64.EFI` from the image
2. reads the existing `.cmdline` section
3. merges in any missing parameters
4. extracts the UKI payload sections needed to rebuild it
5. rebuilds the UKI with `ukify`
6. writes the rebuilt UKI back into the image with `mcopy`

The rebuild logic is in [packages/disk-installer/configure-disk-image.py](/home/hrosten/projects/nixos-android-builder-fork/packages/disk-installer/configure-disk-image.py#L126). The helper gets the `ukify` and EFI stub paths from [packages/disk-installer/default.nix](/home/hrosten/projects/nixos-android-builder-fork/packages/disk-installer/default.nix#L23).

## Why The UKI Is Rebuilt Instead Of Patched In Place

An earlier approach tried to update the UKI's `.cmdline` section in place with `objcopy --update-section`.

That approach was not reliable for this image:

- `objcopy` reported success
- but the resulting UKI still contained the original command line
- so the guest never enabled the serial console early enough for full host-side logging

Rebuilding the UKI with `ukify` makes the resulting embedded command line explicit and verifiable.

## QEMU Side

QEMU is connected to a temporary raw log file by passing:

```text
-serial file:$raw_console_log
```

from the `run-vm` wrapper in [modules/vm.nix](/home/hrosten/projects/nixos-android-builder-fork/modules/vm.nix#L196).

That temporary raw log is then followed by a background sanitizer, currently implemented as:

```text
tail -c +1 -f "$raw_console_log" | stdbuf -oL ansifilter >> "$console_log"
```

This strips terminal control sequences, keeps the host log updating while the VM boots, and then a final `ansifilter` pass is run on exit before the raw log is removed.

This means both of the following work:

- `cat run-vm.console.log`
- `tail -f run-vm.console.log` while the VM is still booting

Because the guest kernel command line includes `console=ttyS0,115200`, QEMU's first serial port becomes the guest serial console and the boot log reaches the host file through that path.

## Verification

The implementation was verified with a real VM boot using:

```shell-session
$ timeout 180s nix run .#run-vm -- -display none
```

The resulting `run-vm.console.log` contained:

- firmware output
- EFI stub output
- kernel boot messages, including the full effective command line
- systemd boot status lines
- `Started Serial Getty on ttyS0`
- the `nixos login:` prompt

## Interaction With Ephemeral VM State

`run-vm` treats the disk image, EFI vars file, and software TPM state as ephemeral by default and removes them on exit.

The console log is different:

- `android-builder_25.11pre-git.qcow2` is removed
- `android-builder-efi-vars.fd` is removed
- `android-builder-swtpm/` is removed
- `run-vm.console.log` is kept on the host

This makes the boot state ephemeral while preserving the host-side log for inspection after the VM exits.

## Limitations

- The kept host log is sanitized, so some raw terminal control traffic is intentionally discarded.
- The current sanitizer uses `ansifilter` for live updates. It removes ESC bytes and most control sequences, but some OSC payloads may still leak through as plain text. In practice this can show up as lines such as `104` or `3008;start=...` near the end of the boot log.
- It is not a structured journal export.
- It does not capture the graphical `tty1` screen contents.
- If a future boot path stops using the image UKI, the cmdline injection step will need to be revisited.

## Related Files

- [modules/vm.nix](/home/hrosten/projects/nixos-android-builder-fork/modules/vm.nix)
- [packages/disk-installer/configure-disk-image.py](/home/hrosten/projects/nixos-android-builder-fork/packages/disk-installer/configure-disk-image.py)
- [packages/disk-installer/default.nix](/home/hrosten/projects/nixos-android-builder-fork/packages/disk-installer/default.nix)
- [docs/user-guide.md](/home/hrosten/projects/nixos-android-builder-fork/docs/user-guide.md)
