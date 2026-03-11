{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixosAndroidBuilder.secureBoot;

  enroll-secure-boot = pkgs.writeShellScriptBin "enroll-secure-boot" ''
    set -xeu
    # Allow modification of efivars
    find \
      /sys/firmware/efi/efivars/ \
      \( -name "db-*" -o -name "KEK-*" \) \
      -exec chattr -i {} \;
    esp_keystore="/boot/KEYS"
    # Append the new allowed signatures, but keep Microsofts and other vendors signatures.
    efi-updatevar -a -f "$esp_keystore/db.auth" db
    # Install Key Exchange Key
    efi-updatevar -f "$esp_keystore/KEK.auth" KEK
    # Install Platform Key (Leaving setup mode and enters user mode)
    efi-updatevar -f "$esp_keystore/PK.auth" PK
    rm -rf $esp_keystore
  '';

  ensureSecureBootEnrollment = pkgs.writeShellScript "ensure-secure-boot-enrollment" ''
    set -euo pipefail

    record_fatal_error() {
      local msg="$1"
      if [ ! -s /run/fatal-error ]; then
        printf '%s\n' "$msg" > /run/fatal-error || true
      fi
      printf '%s\n' "$msg" | systemd-cat -p crit || true
    }

    trap 'status=$?; trap - EXIT; if [ "$status" -ne 0 ] && [ ! -s /run/fatal-error ]; then record_fatal_error "Secure Boot enrollment check failed. Please consult logs (ctrl+alt+f1)."; fi; exit "$status"' EXIT

    sb_status="$(bootctl 2>/dev/null \
    | awk '/Secure Boot:/ {print $3 " " $4}')"

    if [ "$sb_status" = "disabled (setup)" ]
    then
      echo "Secure Boot in Setup Mode, enrolling" | systemd-cat -p info
      ${lib.getExe enroll-secure-boot}
      echo "enrolled. Rebooting..." | systemd-cat -p info
      systemctl --no-block reboot
    elif [ "$sb_status" = "enabled (user)" ]
    then
      echo "Secure Boot active" | systemd-cat -p info
    else
      msg_error="Secure Boot is neither active nor in setup mode. Please enable it in firmware settings."
      record_fatal_error "$msg_error"
      exit 1
    fi
  '';

in
{
  options.nixosAndroidBuilder.secureBoot.enable = lib.mkEnableOption ''
    requiring secure boot during boot and auto-enrolling keys from /boot/KEYS in initrd
  '';

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.efitools
      pkgs.tpm2-tools
      enroll-secure-boot
    ];

    boot.initrd.systemd = {
      initrdBin = [
        pkgs.gawk
        pkgs.efitools
      ];

      storePaths = [
        enroll-secure-boot
        ensureSecureBootEnrollment
      ];

      mounts =
        let
          esp = config.image.repart.partitions."00-esp".repartConfig;
        in
        [
          {
            where = "/boot";
            what = "/dev/disk/by-partlabel/${esp.Label}";
            type = esp.Format;
            unitConfig = {
              DefaultDependencies = false;
            };
            requiredBy = [ "initrd-fs.target" ];
            before = [ "initrd-fs.target" ];
          }
        ];

      services = {
        ensure-secure-boot-enrollment = {
          description = "Ensure secure boot is active. If setup mode, enroll. if disabled, show error";
          wantedBy = [ "initrd.target" ];
          before = [
            "systemd-repart.service"
          ];
          unitConfig = {
            AssertPathExists = "/boot/KEYS";
            RequiresMountsFor = [
              "/boot"
            ];
            DefaultDependencies = false;
            OnFailure = "emergency.target";
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = ensureSecureBootEnrollment;
          };
        };
      };
    };
  };
}
