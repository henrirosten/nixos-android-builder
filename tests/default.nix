{
  pkgs,
  installerModules,
  imageModules,
  nixos,
}:
let
  inherit (pkgs) lib;
  nixosWithBackdoor = nixos.extendModules {
    modules = [
      (
        { modulesPath, ... }:
        {
          imports = [
            "${modulesPath}/testing/test-instrumentation.nix"
          ];
          config = {
            testing = {
              backdoor = true;
              initrdBackdoor = true;
            };
            nixosAndroidBuilder.unattended.enable = lib.mkForce false;
          };
        }
      )
    ];
  };
  nixosSecureBootDisabled = nixos.extendModules {
    modules = [
      {
        config.nixosAndroidBuilder.secureBoot.enable = lib.mkForce false;
      }
    ];
  };
  payload = "${nixosWithBackdoor.config.system.build.finalImage}/${nixosWithBackdoor.config.image.filePath}";
in
{
  secureBootDisabledConfig =
    assert !nixosSecureBootDisabled.config.nixosAndroidBuilder.secureBoot.enable;
    assert nixosSecureBootDisabled.config.boot.initrd.supportedFilesystems.vfat;
    assert !nixosSecureBootDisabled.config.virtualisation.useSecureBoot;
    assert !(nixosSecureBootDisabled.config.system.build ? secureBootKeysForTests);
    assert nixosSecureBootDisabled.config.fileSystems."/usr/bin".fsType == "none";
    assert nixosSecureBootDisabled.config.fileSystems."/usr/bin".depends == [ "/bin" ];
    pkgs.runCommand "secure-boot-disabled-config-check" { } ''
      touch $out
    '';
  integration = pkgs.testers.runNixOSTest {
    imports = [
      ./integration.nix
      {
        _module.args = {
          inherit imageModules;
        };
      }
    ];
  };
  installer = pkgs.testers.runNixOSTest {
    imports = [
      ./installer.nix
      {
        _module.args = {
          inherit payload;
          inherit installerModules;
          vmInstallerTarget = "/dev/vdb";
          vmStorageTarget = "/dev/vdc";
        };
      }
    ];
  };
  installerInteractive = pkgs.testers.runNixOSTest {
    imports = [
      ./installer-interactive.nix
      {
        _module.args = {
          inherit payload;
          inherit installerModules;
          vmInstallerTarget = "select";
          vmStorageTarget = "select";
        };
      }
    ];
  };

  credentialStorage = pkgs.testers.runNixOSTest {
    imports = [ ./credential-storage.nix ];
  };

}
