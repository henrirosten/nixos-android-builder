# Settings which should only be applied if run as a VM, not on bare metal.
{
  lib,
  config,
  ...
}:
let
  cfg = config.virtualisation;
  secureBootCfg = config.nixosAndroidBuilder.secureBoot;
  credentialStorageCfg = config.nixosAndroidBuilder.credentialStorage;
  hostPkgs = cfg.host.pkgs;

  disk-installer = hostPkgs.callPackage ../packages/disk-installer { };
in
{
  config = {
    virtualisation = {
      diskSize = 300 * 1024;
      memorySize = 64 * 1024;
      cores = 32;

      useSecureBoot = secureBootCfg.enable;
      tpm.enable = secureBootCfg.enable || credentialStorageCfg.enable;

      # Don't use direct boot for the VM to verify that the bootloader is working.
      directBoot.enable = false;
      installBootLoader = false;
      useBootLoader = true;
      useEFIBoot = true;
      mountHostNixStore = false;
      efi.OVMF = hostPkgs.OVMFFull;
      efi.keepVariables = false;

      # NixOS overrides filesystems for VMs by default
      fileSystems = lib.mkForce { };
      useDefaultFilesystems = false;

      # Start a headless VM with serial console.
      graphics = true;

      # Use a raw image, not image for the vm (for easier post-processing with mtools & such).
      diskImage = config.image.fileName;

      emptyDiskImages = lib.optionals config.nixosAndroidBuilder.artifactStorage.enable [
        (1024 * 10)
      ];
    };

    system.build =
      lib.optionalAttrs secureBootCfg.enable {
        # Create a set of private keys for VM tests, but cache them in the /nix/store,
        # so we don't need to create a new pair on each run.
        secureBootKeysForTests = hostPkgs.runCommandLocal "test-keys" { } ''
          ${lib.getExe (hostPkgs.callPackage ../packages/secure-boot-scripts { }).create-signing-keys} $out/
        '';
      }
      // {

        # Helper that copies the read-only image out of the nix store to a
        # writable copy in $PWD, optionally signs the UKI for Secure Boot, and
        # configures storage targets for VM tests.
        prepareWritableDisk = hostPkgs.writeShellApplication {
          name = "prepare-writable-disk";
          text =
            let
              cfg = config.virtualisation;
            in
            ''
              disk_image="''${NIX_PREPARE_DISK_IMAGE:-${cfg.diskImage}}"

              if [ ! -e "$disk_image" ]; then

                echo >&2 "Copying ${config.system.build.finalImage}/${config.image.fileName} to $disk_image"
                ${cfg.qemu.package}/bin/qemu-img convert \
                  -f raw -O raw \
                  "${config.system.build.finalImage}/${config.image.fileName}" \
                  "$disk_image"

                echo >&2 "Resizing $disk_image to ${toString cfg.diskSize}M"
                ${cfg.qemu.package}/bin/qemu-img resize \
                  -f raw \
                  "$disk_image" \
                  "${toString cfg.diskSize}M"

                echo >&2 "Preparing $disk_image"
                ${lib.getExe disk-installer.configure} append-cmdline \
                  --device "$disk_image" \
                  --params "systemd.show_status=true rd.systemd.show_status=true systemd.log_level=info console=tty0 console=ttyS0,115200 loglevel=7 panic=1 boot.panic_on_fail"
            ''
            + lib.optionalString secureBootCfg.enable ''
              ${lib.getExe disk-installer.configure} sign \
                --keystore "${config.system.build.secureBootKeysForTests}" \
                --device "$disk_image"
            ''
            + ''
                  ${lib.getExe disk-installer.configure} set-storage \
                    --target "/dev/vdb" \
                    --device "$disk_image"

                else
                  echo "$disk_image already exists, skipping creation${lib.optionalString secureBootCfg.enable " and signing"}"
              fi
            '';
        };

        # Upstream system.build.vm wrapped to prepare a writable image before
        # starting the VM, and sign it when Secure Boot is enabled.
        vmWithWritableDisk = hostPkgs.writeShellApplication {
          name = "run-${config.system.name}-vm";
          runtimeInputs = [
            hostPkgs.coreutils
            hostPkgs.ansifilter
          ];
          text = ''
            cleanup_disk=1
            disk_image="''${NIX_DISK_IMAGE:-./${lib.removeSuffix ".raw" config.image.fileName}.qcow2}"
            efi_vars="''${NIX_EFI_VARS:-./${config.system.name}-efi-vars.fd}"
            swtpm_dir="''${NIX_SWTPM_DIR:-./${config.system.name}-swtpm}"
            console_log="''${RUN_VM_CONSOLE_LOG:-./run-vm.console.log}"
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
                --help|-h)
                  cat <<EOF
            Usage: nix run .#run-vm -- [OPTIONS] [-- VM_ARGS...]

            Options:
              --keep-disk        Keep disk image after VM exits
              --disk-image PATH  Disk image path (default: ./${lib.removeSuffix ".raw" config.image.fileName}.qcow2)
              --help, -h         Show this help text

            Environment:
              NIX_DISK_IMAGE     Override disk image path (default: ./${lib.removeSuffix ".raw" config.image.fileName}.qcow2)
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

            if [ ! -e "$disk_image" ]; then
              tmp_raw="$(mktemp -t ${config.system.name}-disk.XXXXXX.raw)"
              rm -f -- "$tmp_raw"
              export NIX_PREPARE_DISK_IMAGE="$tmp_raw"

              echo "Preparing writable VM disk at $disk_image" >&2
              ${lib.getExe config.system.build.prepareWritableDisk}

              echo "Converting $tmp_raw to $disk_image" >&2
              ${cfg.qemu.package}/bin/qemu-img convert -f raw -O qcow2 "$tmp_raw" "$disk_image"
            else
              echo "$disk_image already exists, reusing it" >&2
            fi

            mkdir -p "$(dirname "$console_log")"
            raw_console_log="$(mktemp -t ${config.system.name}-console.XXXXXX.log)"
            : > "$console_log"

            (
              tail -c +1 -f "$raw_console_log" | stdbuf -oL ansifilter >> "$console_log"
            ) &
            console_filter_pid="$!"

            set -- -serial "file:$raw_console_log" "$@"

            ${lib.getExe config.system.build.vm} "$@"
          '';
        };
      };
  };
}
