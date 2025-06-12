# LUKS Management

This repo contains a number of (bash) scripts that create, mount, unmount
and extend LUKS image files or USB disks, etc, that has an encrypted
ext4 filesystem.

The scripts was developed (2019-2024) on Debian GNU/Linux systems.

## Background

When using a fully encrypted harddisk on a loptop or other computer,
it only protects your sensitive data when the computer is powered off.
Hybernate may be okay, but `suspend to RAM` probably still has your
harddrive's encryption key in RAM.

Sensitive data, like salary reports, git repos, etc, that you rarely look
at or don't use while at a conference or when reading emails at a cafe, can
be stored in a LUKS-encrypted image file and only unlocked when needed.

To further increase security, these scripts support the use of a YubiKey
configured with challenge-response.

### Weaknesses

If your computer is compromised or if onther users has root access to the
computer, it is easy to modify the scripts to copy encryption key(s) used
to unlock the LUKS container(s). The way to protect against this should be
to implement some kind of OTP for LUKS.

In general, any locked LUKS volume will be protected if someone gains
access to your running computer or even grabs your laptop out of your
hands when the screen is unlocked.

## Requirements

On Debian systems, the following packages are required:
(equivalent RPMs, or other package formats, can be used)
- cryptsetup (create, unlock and lock LUKS volumes)
- udisks2 (the udisksctl command for mounting images/volumes, etc)
  (udisks2 recommends 'policykit-1' or 'polkitd' depending on Debian version)
  (and libblockdev-crypto2 and libblockdev-mdraid2 depending on Debian version)
- yubikey-personalization (need when using YubiKey)

Recommended Debian packages:
- a2ps (print out static password during creation of LUKS volume)
- coreutils (shred) or wipe (to remove files with password after print out)
- xclip or wl-clipboard (to copy mount path to clipboard)
  (support for wl-clipboard is not implementetd yet)

On WSL systems, lukscreate.sh also needs 'iconv' command (Debian package: libc-bin)
to handle text output from PowerShell commands.
luks-functions also may use 'usbip' (/usr/sbin/usbip) command, etc
(Recommended Debian packages: hwdata, usbip, usbutils).

For more information about WSL systems, see WSL.md

## Manual installation
The path `/usr/share/bash-completion/completions/` may be different for
other distros than Debian.

```bash
sudo cp -p lib/luks-functions /usr/local/lib/
sudo cp -p bin/lukscreate.sh  /usr/local/bin/lukscreate
sudo cp -p bin/luksextend.sh  /usr/local/bin/luksextend
sudo cp -p bin/luksmount.sh   /usr/local/bin/luksmount
sudo cp -p bin/luksunmount.sh /usr/local/bin/luksunmount
sudo chmod a+x /usr/local/bin/luks*

# Check the destination path
sudo cp -p config/dot.bash_completion /usr/share/bash-completion/completions/luksmount
sudo ln -s luksmount /usr/share/bash-completion/completions/luksextend
sudo ln -s luksmount /usr/share/bash-completion/completions/luksunmount

sudo cp -pi rules.d/71-yubikey.rules /etc/udev/rules.d/
sudo chown root:root /etc/udev/rules.d/71-yubikey.rules
# Older versions of udevadm only has a '--reload' option
sudo udevadm control --reload-rules ; sudo udevadm trigger

# On some systems /etc/polkit-1/rules.d/ is missing
sudo mkdir /etc/polkit-1/rules.d
# On all systems, continue here
sudo cp -p rules.d/10-udisks2-luks-mgmt.rules /etc/polkit-1/rules.d/
sudo chown root:root /etc/polkit-1/rules.d/10-udisks2-luks-mgmt.rules
sudo systemctl restart polkit.service

sudo -s /bin/bash -c 'usermod -a -G plugdev ${SUDO_USER}'

cp -pi config/luks-mgmt.conf $HOME/.config/
```
- Edit $HOME/.config/luks-mgmt.conf to match you settings

```bash
. $HOME/.config/luks-mgmt.conf ; mkdir ${IMAGEPATH}
```

## Webpages about resizing LUKS volumes

https://www.clevernetsystems.com/increase-your-laptops-disk-space/
https://help.ubuntu.com/community/ResizeEncryptedPartitions
https://blog.tinned-software.net/increase-the-size-of-a-luks-encrypted-partition/
https://shaakunthala.wordpress.com/2017/11/28/expanding-a-luks-encrypted-disk-image/
https://unix.stackexchange.com/questions/124669/how-much-storage-overhead-comes-along-with-cryptsetup-and-ext4/124675
