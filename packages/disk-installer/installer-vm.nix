{
  lib,
  config,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.virtualisation.vmVariant.virtualisation;
  hostPkgs = cfg.host.pkgs;
  disk-installer = hostPkgs.callPackage ./. { };
in
{
  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

  options.diskInstaller.vmInstallerTarget = lib.mkOption {
    type = lib.types.str;
    default = "select";
    internal = true;
  };

  options.diskInstaller.vmStorageTarget = lib.mkOption {
    type = lib.types.str;
    default = "select";
    internal = true;
  };

  config = {
    boot.initrd.systemd.services.disk-installer.environment.INSTALLER_COMPLETION_ACTION = "poweroff";

    boot.initrd.systemd.initrdBin = [
      # machine.get_tty_text requries awk
      pkgs.gawk
      # grep is required by the initrd backdoor
      pkgs.gnugrep
    ];

    virtualisation = {
      cores = 8;
      memorySize = 1024 * 8;
      directBoot.enable = false;
      installBootLoader = false;
      useBootLoader = true;
      useEFIBoot = true;
      mountHostNixStore = false;
      efi.keepVariables = false;

      # NixOS overrides filesystems for VMs by default
      fileSystems = lib.mkForce { };
      useDefaultFilesystems = false;

      emptyDiskImages = [
        (1024 * 300)
        # second image for artifact storage if enabled
        (1024 * 10)
      ];
    };

    system.build.prepareInstallerDisk = hostPkgs.writeShellApplication {
      name = "prepare-installer-disk";
      text = ''
        disk_image="''${NIX_PREPARE_DISK_IMAGE:-${cfg.diskImage}}"

        if [ ! -e "$disk_image" ]; then
          echo >&2 "Copying ${config.system.build.image}/${config.image.fileName} to $disk_image"
          ${cfg.qemu.package}/bin/qemu-img convert \
            -f raw -O raw \
            "${config.system.build.image}/${config.image.fileName}" \
            "$disk_image"

          echo >&2 "Preparing $disk_image"
          ${lib.getExe disk-installer.configure} set-target --target "${config.diskInstaller.vmInstallerTarget}" --device "$disk_image"
          ${lib.optionalString (config.diskInstaller.vmStorageTarget != "select") ''
            ${lib.getExe disk-installer.configure} set-storage --target "${config.diskInstaller.vmStorageTarget}" --device "$disk_image"
          ''}
        else
          echo "$disk_image already exists, skipping creation"
        fi
      '';
    };

    system.build.vmWithInstallerDisk = hostPkgs.writeShellApplication {
      name = "run-${config.system.name}-vm";
      runtimeInputs = [
        hostPkgs.coreutils
        hostPkgs.ansifilter
      ];
      text = ''
        cleanup_disk=1
        disk_image="''${NIX_DISK_IMAGE:-./${lib.removeSuffix ".raw" config.image.fileName}.qcow2}"
        vm_state_dir="''${NIX_VM_STATE_DIR:-./.installer-vm-state}"
        installed_disk=""
        efi_vars="''${NIX_EFI_VARS:-./${config.system.name}-efi-vars.fd}"
        swtpm_dir="''${NIX_SWTPM_DIR:-./${config.system.name}-swtpm}"
        console_log="''${RUN_VM_CONSOLE_LOG:-./installer-vm.console.log}"
        tmp_raw=""
        raw_console_log=""
        console_filter_pid=""

        while [ "$#" -gt 0 ]; do
          case "$1" in
            --keep-disk)
              cleanup_disk=0
              shift
              ;;
            --disk-image)
              if [ "$#" -lt 2 ]; then
                echo "error: --disk-image requires a path argument" >&2
                exit 2
              fi
              disk_image="$2"
              shift 2
              ;;
            --vm-state-dir)
              if [ "$#" -lt 2 ]; then
                echo "error: --vm-state-dir requires a path argument" >&2
                exit 2
              fi
              vm_state_dir="$2"
              shift 2
              ;;
            --installed-disk)
              if [ "$#" -lt 2 ]; then
                echo "error: --installed-disk requires a path argument" >&2
                exit 2
              fi
              installed_disk="$2"
              shift 2
              ;;
            --help|-h)
              cat <<EOF
        Usage: nix run .#installer-vm -- [OPTIONS] [-- VM_ARGS...]

        Options:
          --keep-disk        Keep disk image after VM exits
          --disk-image PATH  Disk image path (default: ./${lib.removeSuffix ".raw" config.image.fileName}.qcow2)
          --vm-state-dir PATH
                            Directory used for qemu-vm state (default: ./.installer-vm-state)
          --installed-disk PATH
                            Disk to boot after installation
                            (default: ./.installer-vm-state/empty0.qcow2)
          --help, -h         Show this help text

        Environment:
          NIX_DISK_IMAGE     Override disk image path (default: ./${lib.removeSuffix ".raw" config.image.fileName}.qcow2)
          NIX_VM_STATE_DIR   Override qemu-vm state directory (default: ./.installer-vm-state)
          NIX_INSTALLER_BOOT_DISK
                            Override installed target disk path
                            (default: ./.installer-vm-state/empty0.qcow2)
        EOF
              exit 0
              ;;
            --)
              shift
              break
              ;;
            *)
              break
              ;;
          esac
        done

        disk_image="$(readlink -m "$disk_image")"
        vm_state_dir="$(readlink -m "$vm_state_dir")"
        if [ -z "$installed_disk" ]; then
          installed_disk="$vm_state_dir/empty0.qcow2"
        fi
        installed_disk="$(readlink -m "$installed_disk")"
        efi_vars="$(readlink -m "$efi_vars")"
        swtpm_dir="$(readlink -m "$swtpm_dir")"
        console_log="$(readlink -m "$console_log")"

        cleanup() {
          status="$?"
          if [ -n "$console_filter_pid" ]; then
            kill "$console_filter_pid" 2>/dev/null || true
            wait "$console_filter_pid" 2>/dev/null || true
          fi
          if [ -n "$raw_console_log" ] && [ -f "$raw_console_log" ]; then
            ansifilter --input="$raw_console_log" --output="$console_log"
            rm -f -- "$raw_console_log"
          fi
          if [ -n "$tmp_raw" ] && [ -e "$tmp_raw" ]; then
            rm -f -- "$tmp_raw"
          fi
          if [ "$cleanup_disk" -eq 1 ] && [ -f "$disk_image" ]; then
            rm -f -- "$disk_image"
          fi
          if [ "$cleanup_disk" -eq 1 ] && [ -d "$vm_state_dir" ]; then
            rm -rf -- "$vm_state_dir"
          fi
          if [ "$cleanup_disk" -eq 1 ] && [ -f "$installed_disk" ] && [ "$installed_disk" != "$disk_image" ]; then
            rm -f -- "$installed_disk"
          fi
          if [ "$cleanup_disk" -eq 1 ] && [ -f "$efi_vars" ]; then
            rm -f -- "$efi_vars"
          fi
          if [ "$cleanup_disk" -eq 1 ] && [ -d "$swtpm_dir" ]; then
            rm -rf -- "$swtpm_dir"
          fi
          exit "$status"
        }

        trap cleanup EXIT INT TERM

        export NIX_DISK_IMAGE="$disk_image"
        export NIX_EFI_VARS="$efi_vars"
        export NIX_SWTPM_DIR="$swtpm_dir"
        export TMPDIR="$vm_state_dir"
        export USE_TMPDIR=1

        mkdir -p "$vm_state_dir"

        run_vm_phase() {
          raw_console_log="$(mktemp -t ${config.system.name}-console.XXXXXX.log)"
          (
            tail -c +1 -f "$raw_console_log" | stdbuf -oL ansifilter >> "$console_log"
          ) &
          console_filter_pid="$!"

          set -- -serial "file:$raw_console_log" "$@"
          ${lib.getExe config.system.build.vm} "$@"

          kill "$console_filter_pid" 2>/dev/null || true
          wait "$console_filter_pid" 2>/dev/null || true
          console_filter_pid=""
          rm -f -- "$raw_console_log"
          raw_console_log=""
        }

        if [ ! -e "$disk_image" ]; then
          tmp_raw="$(mktemp -t ${config.system.name}-installer.XXXXXX.raw)"
          rm -f -- "$tmp_raw"
          export NIX_PREPARE_DISK_IMAGE="$tmp_raw"

          echo "Preparing writable installer disk at $disk_image" >&2
          ${lib.getExe config.system.build.prepareInstallerDisk}

          echo "Converting $tmp_raw to $disk_image" >&2
          ${cfg.qemu.package}/bin/qemu-img convert -f raw -O qcow2 "$tmp_raw" "$disk_image"
        else
          echo "$disk_image already exists, reusing it" >&2
        fi

        mkdir -p "$(dirname "$console_log")"
        : > "$console_log"

        echo "Starting installer VM from $disk_image" >&2
        run_vm_phase "$@"

        if [ ! -f "$installed_disk" ]; then
          echo "warning: installed target disk $installed_disk was not created; not starting second boot" >&2
          exit 0
        fi

        if [ "$installed_disk" != "$disk_image" ]; then
          rm -f -- "$disk_image"
          mv -- "$installed_disk" "$disk_image"
        fi

        echo "Starting installed system from $disk_image" >&2
        run_vm_phase "$@"
      '';
    };
  };
}
