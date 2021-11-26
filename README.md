# LUKS Management

This repo contains a number of (bash) scripts that creates, mounts,
unmounts and extend LUKS image files or USB disks, etc, that has an
encrypted ext4 filesystem.

The scripts was (2019-2021) developed on Debian GNU/Linux systems.

## Requirements

On Debian systems, the following packages are required:
(equivalent RPMs, or other package formats, can be used)
- cryptsetup (create, unlock and lock LUKS volumes)
- udisks2 (the udisksctl command for mounting images/volumes, etc)
- yubikey-personalization (need when using YubiKey)

Recommended Debian packages:
- a2ps (print out static password during creation of LUKS volume)
- coreutils (shred) or wipe (to remove files with password after print out)
- xclip (to copy mount path to clipboard)

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

sudo cp -pi rules-d/71-yubikey.rules /etc/udev/rules.d/
sudo chown root:root /etc/udev/rules.d/71-yubikey.rules
# Older versions of udevadm only has a '--reload' option
sudo udevadm control --reload-rules ; sudo udevadm trigger

cp -pi config/luks-mgmt.conf $HOME/.config/
```

## Webpages about resizing LUKS volumes

https://www.clevernetsystems.com/increase-your-laptops-disk-space/
https://help.ubuntu.com/community/ResizeEncryptedPartitions
https://blog.tinned-software.net/increase-the-size-of-a-luks-encrypted-partition/
https://shaakunthala.wordpress.com/2017/11/28/expanding-a-luks-encrypted-disk-image/
https://unix.stackexchange.com/questions/124669/how-much-storage-overhead-comes-along-with-cryptsetup-and-ext4/124675
