# TODO

This is an unprioritized list of ideas with improvements.

## lib/luks-functions

 - Auto attach, if single YubiKey connected/shared in WSL
   (now handled by Bash alias for luksmount.sh, see config/dot.bash_wsl_aliases)

## bin/lukscreate.sh

 - Change keep behavior of printout file, if not printing

## bin/lukscreate.sh, bin/luksextend.sh

 - Accept size as commandline options

## bin/luksmount.sh, config/dot.bash_completion

 - For luksmount.sh the bash-completion should skip already mounted volumes

 - luksmount.sh without parameters should list mountpoint for mounted volumes

 - add option to mount filesystem read-only

## bin/luksextend.sh

 - should deny extending filesystem mounted in read-only mode

## bin/luksmount.sh, bin/luksunmount.sh

 - Mount and unmount multiple volumes
