{ lib, pkgs, ... }:

let
  targets = {
    emergency = {
      wants = [ "fatal-error.service" ];
    };
  };
  services = {
    # We want to display our error, not panic
    panic-on-fail.enable = lib.mkForce false;

    # Upstreams emergency.service would grab the whole tty in case
    # emergencyAccess is enabled.
    emergency = {
      serviceConfig = {
        ExecStartPre = lib.mkForce [ "" ];
        ExecStart = lib.mkForce [
          ""
          "${pkgs.coreutils}/bin/true"
        ];
        StandardInput = lib.mkForce "null";
        StandardOutput = lib.mkForce "null";
      };
    };

    fatal-error = {
      description = "Display a fatal error to the user";

      after = [ "systemd-udevd.service" ];
      requires = [ "systemd-udevd.service" ];
      unitConfig = {
        DefaultDependencies = "no";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardInput = "tty-force";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = "/dev/tty2";
        TTYReset = true;
        Restart = "no";
      };

      path = [
        pkgs.coreutils
        pkgs.dialog
        pkgs.kbd
        pkgs.systemd
      ];

      script = ''
        chvt 2

        # Without those udevadm commands, we might not yet have keyboard input
        # if we entered the emergency target too early
        udevadm trigger --action=add
        udevadm settle --timeout=10

        lines=$(tput lines 2>/dev/null || echo 24)
        cols=$(tput cols 2>/dev/null || echo 80)
        box_height=$((lines > 6 ? lines - 4 : lines))
        box_width=$((cols > 6 ? cols - 4 : cols))

        if [ -s /run/fatal-error ]; then
          dialog \
              --clear \
              --colors \
              --ok-button " Shutdown " \
              --title "Error" \
              --msgbox "$(cat /run/fatal-error 2>/dev/null)" \
              "$box_height" "$box_width"
        else
          diagnostics="$(mktemp)"
          {
            echo "fatal-error.service was started without /run/fatal-error."
            echo
            echo "Failed units:"
            systemctl --failed --no-legend --plain 2>/dev/null || true
            echo
            echo "Recent error logs:"
            journalctl -b -p warning..alert -n 40 \
              --no-pager --output=short-monotonic 2>/dev/null || true
          } > "$diagnostics"
          dialog \
              --clear \
              --colors \
              --ok-button " Shutdown " \
              --title "Error Details" \
              --textbox "$diagnostics" \
              "$box_height" "$box_width"
        fi
        chvt 1
        systemctl --no-block poweroff
      '';
    };
  };
in
{
  boot.initrd.systemd = {
    inherit targets services;
    contents."/etc/terminfo".source = "${pkgs.ncurses}/share/terminfo";
    extraBin = {
      cat = "${pkgs.coreutils}/bin/cat";
      dialog = "${pkgs.dialog}/bin/dialog";
      chvt = "${pkgs.kbd}/bin/chvt";
    };
  };
  systemd = {
    inherit targets services;
  };
  environment.systemPackages = [
    pkgs.dialog
    pkgs.kbd
  ];
}
