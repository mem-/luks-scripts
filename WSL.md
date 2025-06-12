# LUKS scripts on WSL

To use PolicyKit to handle access to YubiKeys, you need to activate Systemd.

To minimize problems with Windows HyperV firewall and the USBIPD,
use WSL networking in mirrored mode.

For now (spring 2025) the WSL Linux kernel doesn't support USB storage.
But the 'wsl' command in PowerShell can be used to access non windows disks.

## Systemd

  https://learn.microsoft.com/en-us/windows/wsl/systemd

  /etc/wsl.conf

    [boot]
    systemd=true

## Mirrored mode

  https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking

  - Create or update the following file:

   /mnt/c/Users/$(whoami)/.wslconfig

    [wsl2]
    networkingMode=mirrored
    dnsTunneling=true

## Install USBIPD, etc

  https://learn.microsoft.com/en-us/windows/wsl/connect-usb
  https://github.com/dorssel/usbipd-win/wiki/WSL-support

  - Use winget to install USBIPD in a PowerShell with admin rights:

  PS> winget install --interactive --exact dorssel.usbipd-win

## USB storage

  To access disks using the 'wsl.exe' command in PowerShell, see

  - https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk

  - Inside WSL, use PowerShell.exe for commands that need Local-Admin rights, or other PowerShell modules

```bash
# 'set -f' inside parentheses command to temporary disable bash globbing
( set -f ; powershell.exe GET-CimInstance -query \"SELECT * from Win32_DiskDrive\" )

# Attach a raw (bare) block-device disk inside WSL
# wsl.exe has to run with Local-Admin rights, done with 'powershell.exe Start-Process -Verb runAs'
powershell.exe Start-Process -Verb runAs -FilePath \"wsl.exe\" -ArgumentList \"--mount \\\\.\\PHYSICALDRIVEx --bare\"

# Detach a disk from WSL (doesn't need Local-Admin)
wsl.exe --unmount \\\\.\\PHYSICALDRIVEx
```

### Optional: Recompile WSL Linux kernel

  The following web pages gives some guidelines of how to compile your own WSL kernel:

  - https://www.reddit.com/r/bashonubuntuonwindows/comments/17chaed/how_to_mount_usb_device_after_installing_usbipdwin/

  - https://github.com/microsoft/WSL2-Linux-Kernel/releases

  - https://askubuntu.com/questions/1454199/how-can-i-mount-a-removable-usb-drive-in-wsl
