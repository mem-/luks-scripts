#!/bin/bash
# bash is needed to use 'read' command that has silent mode to not echo passphrase
#
# Version 2.3 Copyright (c) Magnus (Mem) Sandberg 2019-2020,2022
# Email: mem (a) datakon , se
#
# Created by Mem, 2019-05-29
#
# Inspired by 'yubikey-luks-enroll' from yubikey-luks, https://github.com/cornelinux/yubikey-luks
# Also inspired by my own 'tcmount' script for mount TrueCrypt volumes
#
# Developed for udisks2 2.8.1-4 (Debian 10.x Buster)
#
# Depends on the following Debian packages: cryptsetup-bin, udisks2, yubikey-personalization (need when using YubiKey)
# Recommended Debian packages:              a2ps, wipe
#
# Required luks-functions version
REQ_LUKS_FUNCTIONS_MAJOR="1"
REQ_LUKS_FUNCTIONS_MINOR="6"
#
# Default settings, change by edit $HOME/.config/luks-mgmt.conf
CONCATENATE=0
HASH=0
SLOT=7
YKSLOT="2"
SPARSE=0
SUCMD="su --login -c"
IMAGEPATH="$HOME/.images"
CONFIG=$HOME/.config/luks-mgmt.conf
[ -f $CONFIG ] && . $CONFIG

# Commandline options and device type
DEBUG=0
# State of things before the run of this script
PHYSDEV=0
PRINTOUT=0
PRINTFILE=0
loop_before=0
fsdev_before=0  # will never change in this script,
		# just here to handle failed mount the same way as other scripts

if [ "x$1" = "x-v" ] ; then
    DEBUG=1
    shift
fi

if [ "x$1" = "x" ] || [ "x$1" = "x-h" ] ; then
    echo
    echo "Usage: $0 [-h] [-v] <volume>"
    echo
    echo " -h       : Show this help text"
    echo " -v       : Verbose mode"
    echo
    echo " <volume> : The volume filename to be created, with or without '.img' extension"
    echo "          : volume will be created in ${IMAGEPATH}/"
    echo "          :"
    echo "          : The volume can also be a physical device, like USB stick,"
    echo "          : by entering the device path. Example: /dev/sdb1"
    echo "          :"
    echo "          :To change path, edit ${CONFIG}"
    echo
    exit
fi

if ! which udisksctl >/dev/null 2>&1 ; then
    echo "This script needs 'udisksctl' command (Debian package: udisks2), exiting."
    exit 1
fi

if ! which cryptsetup >/dev/null 2>&1 ; then
    echo "This script needs 'cryptsetup' command (Debian package: cryptsetup-bin), exiting."
    exit 1
fi

# Find location of this script it self to locate functions to include
# Search path /lib/luks-mgmt/luks-functions, DIRNAME($0)/../lib/luks-functions, DIRNAME($0)/luks-functions,
# https://www.cyberciti.biz/faq/unix-linux-appleosx-bsd-bash-script-find-what-directory-itsstoredin/

[ $DEBUG -gt 0 ] && echo "Looking for 'luks-functions' location"
if [ -r /lib/luks-mgmt/luks-functions ]; then
    [ $DEBUG -gt 0 ] && echo "Sourcing /lib/luks-mgmt/luks-functions"
    . /lib/luks-mgmt/luks-functions
else
    # Find location of this script it self
    _scriptdir="$( dirname $( readlink -f ${BASH_SOURCE[0]} ) )"
#   [ $DEBUG -gt 0 ] && echo "Script's location: $_scriptdir"
    _libdir="$( echo $_scriptdir | sed -e 's#/$##' | sed -e 's/[^/]\+$/lib/' )"
#   [ $DEBUG -gt 0 ] && echo "Lib dir: $_libdir"

    if [ -r $_libdir/luks-functions ]; then
	[ $DEBUG -gt 0 ] && echo "Sourcing $_libdir/luks-functions"
	. $_libdir/luks-functions
    elif [ -r $_scriptdir/luks-functions ]; then
	[ $DEBUG -gt 0 ] && echo "Sourcing $_scriptdir/luks-functions"
	. $_scriptdir/luks-functions
    else
	echo "Could not find any 'luks-functions' to include!"
	exit 1
    fi
fi

if [ "x${LUKS_FUNCTIONS_MAJOR}" = "x" ] ; then
    echo "Could not find LUKS_FUNCTIONS_MAJOR, luks-functions file too old."
    exit 1
fi
if [ "x${LUKS_FUNCTIONS_MINOR}" = "x" ] ; then
    echo "Could not find LUKS_FUNCTIONS_MINOR, luks-functions file too old."
    exit 1
fi
[ $DEBUG -gt 0 ] && echo "LUKS_FUNCTIONS_MAJOR: ${LUKS_FUNCTIONS_MAJOR}"
[ $DEBUG -gt 0 ] && echo "LUKS_FUNCTIONS_MINOR: ${LUKS_FUNCTIONS_MINOR}"
if [ ${LUKS_FUNCTIONS_MAJOR} -ne ${REQ_LUKS_FUNCTIONS_MAJOR} ] ; then
    echo
    echo "Found LUKS_FUNCTIONS_MAJOR: ${LUKS_FUNCTIONS_MAJOR}"
    echo "This script needs major verion: ${REQ_LUKS_FUNCTIONS_MAJOR}"
    exit 1
fi
if [ ${LUKS_FUNCTIONS_MINOR} -lt ${REQ_LUKS_FUNCTIONS_MINOR} ] ; then
    echo
    echo "Found LUKS_FUNCTIONS_MINOR: ${LUKS_FUNCTIONS_MINOR}"
    echo "This script needs minor verion ${REQ_LUKS_FUNCTIONS_MINOR} or higher."
    exit 1
fi

if which shred >/dev/null 2>&1 ; then
    rmcmd="shred --remove --zero"
elif which wipe >/dev/null 2>&1 ; then
    rmcmd="wipe"
else
    rmcmd="rm"
fi

cleanup_tmp () {
    if [ -e $tempdir ] ; then
	echo "Cleaning up $tempdir"
	[ $DEBUG -gt 0 ] && echo "Using '${rmcmd}' to remove files"
	$rmcmd 2>/dev/null $tempdir/*.txt
	rmdir $tempdir
    fi
}

cleanup_all () {
    if [ ${PHYSDEV} -eq 0 ] && [ "x${IMAGEPATH}" != "x" ] && [ "x${volume}" != "x" ] && [ -f ${IMAGEPATH}/${volume}.img ] ; then
	echo "Removing ${IMAGEPATH}/${volume}.img"
	rm ${IMAGEPATH}/${volume}.img
    elif [ $DEBUG -gt 0 ] ; then
	echo "Inside cleanup_tmp()"
	echo "PHYSDEV:   ${PHYSDEV}"
	echo "IMAGEPATH: ${IMAGEPATH}"
	echo "volume:    ${volume}"
	echo -n "${IMAGEPATH}/${volume}.img "
	[ -e ${IMAGEPATH}/${volume}.img ] && echo "does exist..." || echo "doesn't exist as expected."
    fi
    cleanup_tmp
}


# Validate volume (file) name
R=$( valid_volume "$1" ) ; RC=$?
if echo "$R" | grep "^/dev/" >/dev/null ; then
    PHYSDEV=1
    [ $DEBUG -gt 0 ] && echo "Block device: ${R}."
elif [ $RC -eq 0 ] ; then
    echo "Volume ${IMAGEPATH}/${R}.img already exists."
    exit 1
elif [ $RC -gt 1 ] ; then
    # not a block device, not regular file, or dangerous filename, etc
    echo "$R" ; exit $RC
fi
volume="$R"

# Tempdir used for print-out and parameters to 'su' commands
tempdir=/tmp/lukstemp
if [ -e $tempdir ] ; then
    echo "Can't create directory ${tempdir}, file or directory already exists."
    exit 1
fi
mkdir $tempdir
chmod 700 $tempdir

echo
echo "Configuration values that will be used:"
echo
echo "\$CONCATENATE=\"${CONCATENATE}\"         ; concatenate passphrase or hash with resonse from YubiKey"
echo "\$HASH=\"${HASH}\"                ; hash passphrase before sending to YubiKey"
echo "\$SLOT=\"${SLOT}\"                 ; LUKS keyslot to store challenge-response unlock data"
echo "\$YKSLOT=\"${YKSLOT}\"              ; YubiKey slot used for challenge-response"
echo "\$SPARSE=\"${SPARSE}\"              ; create sparse image or regular image file"
echo "\$SUCMD=\"${SUCMD}\"   ; how to become root for some commands"
[ $PHYSDEV -eq 0 ] && echo "\$IMAGEPATH=\"${IMAGEPATH}\""
echo
echo "To change values, edit ${CONFIG}"
echo "NOTICE: Changing values may affect mounting of already created volumes."
echo
read -p "Continue (Y/n): " R
case $R in
    n|N|[nN][oO]|q|Q|[qQ][uU][iI][tT])
	echo "Exiting."
	cleanup_tmp
	exit
	;;
    *)
	[ $DEBUG -gt 0 ] && echo -e "Continuing.\n"
	;;
esac

# Use more to have paging only if needed
more <<'_EOT'

This script can help you create a static password for your LUKS volume
and/or a passphrase used together with YubiKey Challenge-Response.

It is not recommended to store static password on YubiKey in static password
mode. If someone can access your YubiKey just for a few seconds it is easy to
copy the static password from the YubiKey. Even if the LUKS password is
combined with a manually entered passphrase followed by the YubiKey password,
the individual that at some point copied your YubiKey now only need to see
when you enter the manual part of the password to have all parts of
the LUKS passphrase to unlock your LUKS volume without you knowing.
This weakness is mainly relevant for encypted boot disks, if the individual
can boot your computer without you knowing. For encrypted LUKS images
the individual has to have access to your computer in a way to get access to
the LUKS image file.

You will first be asked to set up a static password or just skip to the
Challenge-Response setup. If you set up a static password you can decide to
manually enter a password or let the script generate a random password for you
with a length you decide. You will also have the option to print out
the static password to store as backup at a secure location.

You don't need to setup a static password if using Challenge-Response, but it
is recommended to have a long random password as last resort if you loose your
YubiKey or if the YubiKey breaks.
The Challenge-Response is optional but recommended as static passwords often
are weak, as easy-to-remember passwords also are easy to guess or break.

To use YubiKey with Challenge-Response make sure you've setup your YubiKey
before continuing. To setup Challenge-Response make sure your computer has
needed 'udev' config to allow user access to the YubiKey. Read the man-page
for the 'ykchalresp' command to setup and test your YubiKey. My recommended
setup command is:

ykpersonalize -v -2 -ochal-resp -ochal-hmac -ohmac-lt64 -oserial-api-visible -ochal-btn-trig

I use '-ochal-btn-trig' to prevent other scripts or (remote) users logged in
at the same computer to use the YubiKey without the need to press the
YubiKey button.

_EOT

read -p "Continue (y/N): " R
case $R in
    y|Y|[yY][eE][sS])
	[ $DEBUG -gt 0 ] && echo "Continuing."
	;;
    *)
	echo "Exiting."
	cleanup_tmp
	exit
	;;
esac
echo

if [ $PHYSDEV -eq 0 ] ; then
    echo "Setting up LUKS volume in image file ${IMAGEPATH}/${volume}.img"
    echo "NOTE: LUKS2 metadata normally uses 16M of the image size!"
    read -p "Enter image size in 'dd' format (512M, 1G, etc): " R
    numsize=$( human_to_number "${R}" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "$numsize"
	cleanup_tmp
	exit $RC
    fi
    if [ $numsize -lt 20000000 ] ; then
	echo "Volume size less than 20MB is not recommended."
	cleanup_tmp
	exit 1
    fi
    if [ $SPARSE -gt 0 ] ; then
	# Using 'if [[ ]]' as case statements doesn't do regex
	if [[ "$R" =~  ^[0-9]+[cwb]?$ ]] ||
	   [[ "$R" =~ ^[0-9]+[kMGTPEZY]B$ ]] ||
	   [[ "$R" =~ ^[0-9]+[KMGTPEZY]$ ]] ; then
	    BS=1
	else
	    echo "Unknown size value for 'dd': $R"
	    cleanup_tmp
	    exit 1
	fi
	blocks="$R"
	[ $DEBUG -gt 0 ] && echo "Block size for dd: $BS"
	[ $DEBUG -gt 0 ] && echo "Number of blocks to create: ${blocks}"

	if [ $DEBUG -gt 0 ] ; then
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=0 seek=$blocks
	else
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=0 seek=$blocks 2>&1 | egrep -v ' records | copied, '
	fi
    else
	# Using 'if [[ ]]' as case statements doesn't do regex
	if [[ "$R" =~  ^[0-9]+[cw]?$ ]] ; then
	    BS=1
	elif [[ "$R" =~ ^[0-9]+b$ ]] ; then
	    BS=512
	    R=$( echo $R | tr -d 'b' )
	elif [[ "$R" =~ ^[0-9]+[kMGTPEZY]B$ ]] ; then
	    BS=1000
	    R=$( echo $R | sed -e 's/kB$//' | tr 'MGTPEZY' 'kMGTPEZ' )
	elif [[ "$R" =~ ^[0-9]+[KMGTPEZY]$ ]] ; then
	    BS=1024
	    R=$( echo $R | tr -d 'K' | tr 'MGTPEZY' 'KMGTPEZ' )
	else
	    echo "Unknown size value for 'dd': $R"
	    cleanup_tmp
	    exit 1
	fi
	[ $DEBUG -gt 0 ] && echo "Block size for dd: $BS"
	[ $DEBUG -gt 0 ] && echo "Number of blocks to create: $R"

	if [ $DEBUG -gt 0 ] ; then
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=$R
	else
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=$R 2>&1 | egrep -v ' records | copied, '
	fi
    fi
else
    echo
    echo " !!!"
    echo " !!! ALL DATA ON DEVICE $volume WILL BE ERASED"
    echo " !!!"
    echo " !!! Enter 'Yes' in uppercase to continue."
    echo " !!!"

    read -p "Continue: " R
    case $R in
	YES)
	    [ $DEBUG -gt 0 ] && echo "Continuing."
	    ;;
	*)
	    echo "You didn't answer 'YES', exiting."
	    cleanup_tmp
	    exit
	    ;;
    esac

    echo
    echo " >>>"
    echo " >>> Really overwrite $volume ?"
    echo " >>>"
    echo " >>> Enter 'Yes' in uppercase once more to continue."
    echo " >>>"

    read -p "Continue: " R
    case $R in
	YES)
	    [ $DEBUG -gt 0 ] && echo "Continuing."
	    ;;
	*)
	    echo "You didn't answer 'YES', exiting."
	    cleanup_tmp
	    exit
	    ;;
    esac
    echo
fi

if [ $PHYSDEV -eq 0 ] ; then
    echo
    echo "Select preferred mount-name, usually mounted under /media/$USER/,"
    echo "like /media/$USER/$volume"
    echo "The mount-name can be changed by root with 'tune2fs -L <new-name> <dev>',"
    echo " where <dev> usually is something like /dev/dm-X."
    read -p "Enter mount-name (default: $volume): " label
    [ -z $label ] && label=$volume
else
    echo
    echo "Select preferred mount-name, usually mounted under /media/$USER/,"
    echo "like /media/$USER/USB-encrypted"
    echo "The mount-name can be changed by root with 'tune2fs -L <new-name> <dev>',"
    echo "where <dev> usually is something like $volume."
    read -p "Enter mount-name (default: USB-encrypted): " label
    [ -z $label ] && label="USB-encrypted"
fi

echo
echo "Preparing for password generation and optional print-out."

read -p "Use static password, as backup or regular use (Y/n): " R
case $R in
    n|N|[nN][oO])
	STATICPW=0
	;;
    *)
	STATICPW=1
	read -p "Would you like to print out the password to store safely (Y/n): " R
	case $R in
	    n|N|[nN][oO])
		PRINTOUT=0
		read -p "Would you like to create a print file with the password to store safely (Y/n): " R
		case $R in
		    n|N|[nN][oO])
			PRINTFILE=0
			;;
		    *)
			PRINTFILE=1
			;;
		esac
		;;
	    *)
		PRINTOUT=1 ; PRINTFILE=1
		;;
	esac

	if [ $PRINTFILE -gt 0 ] ; then
	    echo "Date: $(date +%Y-%m-%d)" > $tempdir/file.txt
	    chmod 600 $tempdir/file.txt
	    if [ $PHYSDEV -eq 0 ] ; then
		echo "LUKS image: $(hostname -s):${IMAGEPATH}/${volume}.img" >> $tempdir/file.txt
	    else
		echo "LUKS image: $(hostname -s):${volume} (Labeled: ${label})" >> $tempdir/file.txt
	    fi
	    echo "" >> $tempdir/file.txt
	fi

	read -p "Auto-generate password, or enter manually (A/m): " R
	case $R in
	    m|M|[mM][aA][nN]*)
		AUTOGEN=0
		echo "Password should be 10-99 characters."
		read -s -p "Enter password: " PW1 ; echo
		read -s -p "Enter again:    " PW2 ; echo
		if [ "$PW1" != "$PW2" ]; then
		    echo "Passwords do not match, try again."
		    read -s -p "Enter password: " PW1 ; echo
		    read -s -p "Enter again:    " PW2 ; echo
		    if [ "$PW1" != "$PW2" ]; then
			echo "Passwords do not match, exiting."
			unset PW1 ; unset PW2
			cleanup_all
			exit 1
		    fi
		fi
		unset PW2
		if [ ${#PW1} -lt 10 ] || [ ${#PW1} -gt 99 ] ; then
		    echo "Wrong length of password (should be 10-99 characters): ${#PW1}"
		    read -s -p "Enter password: " PW1 ; echo
		    read -s -p "Enter again:    " PW2 ; echo
		    if [ "$PW1" != "$PW2" ]; then
			echo "Passwords do not match, exiting."
			unset PW1 ; unset PW2
			cleanup_all
			exit 1
		    fi
		    unset PW2
		    if [ ${#PW1} -lt 10 ] || [ ${#PW1} -gt 99 ] ; then
			echo "Wrong length again, exiting."
			unset PW1
			cleanup_all
			exit 1
		    fi
		fi
		;;
	    *)
		AUTOGEN=1
		read -p "Enter password length to create, allowed 10-99 characters (default 32): " R
		case $R in
		    [1-9][0-9])
			PWLEN=$R
			;;
		    '')
			PWLEN=32
			;;
		    *)
			echo "Wrong value: $R"
			cleanup_all
			exit 1
			;;
		esac
		[ $DEBUG -gt 0 ] && echo "Chars: $PWLEN"

		echo "Allow special chars that has same location in most keyboard layouts (,.!%),"
		read -p "otherwise only A-Z,a-z,0-9 (Y/n): " R
		case $R in
		    n|N|[nN][oO])
			PW1=$( cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c $PWLEN )
			;;
		    *)
			PW1=$( cat /dev/urandom | tr -dc 'A-Za-z0-9,.!%' | head -c $PWLEN )
			;;
		esac
		;;
	esac
	[ $DEBUG -gt 0 ] && [ $AUTOGEN -gt 0 ] && echo -e "\nAutogenerated password: $PW1"

	if [ $PRINTFILE -gt 0 ] ; then
	    echo "Password: $PW1" >> $tempdir/file.txt
	    echo
	    if [ $PRINTOUT -gt 0 ] ; then
		echo "Select printer:"
		lpstat -p | awk '{ print $2 }'
		defaultprinter=$( lpstat -d ) #; echo $defaultprinter
		defaultprinter=$( echo $defaultprinter | cut -d':' -f2 | awk '{ print $1 }' )

		read -p "Which printer to use ('none' to skip print-out) (default: $defaultprinter): " printer
		[ -z $printer ] && printer=$defaultprinter
		if [ ! "x$printer" = "xnone" ] ; then
		    printerstatus=$( lpstat 2>/dev/null -p $printer ) ; RC=$?
		    if [ $RC -gt 0 ] ; then
			echo "Unknown printer: $printer"
			read -p "Which printer to use (default: $defaultprinter): " printer
			[ -z $printer ] && printer=$defaultprinter
			if [ ! "x$printer" = "xnone" ] ; then
			    printerstatus=$( lpstat 2>/dev/null -p $printer ) ; RC=$?
			    if [ $RC -gt 0 ] ; then
				echo "Unknown printer: ${printer}, exiting."
				unset PW1
				cleanup_all
				exit 1
			    fi
			fi
		    fi
		fi
		[ $DEBUG -gt 0 ] && echo "Printer: $printer"
		if [ ! "x$printer" = "xnone" ] ; then
		    if which a2ps >/dev/null 2>&1 ; then
			read -p "Found 'a2ps' command. Use 'a2ps' for pretty printing (Y/n): " R
			case $R in
			    n|N|[nN][oO])
				printcmd="lpr"
				;;
			    *)
				printcmd="a2ps -q -1Rl80 --center-title=${volume}"
				;;
			esac
		    fi
		    if [ "x$printer" != "xnone" ] ; then
			$printcmd -P $printer $tempdir/file.txt
			read -p "Print a second copy (Y/n): " R
			case $R in
			    n|N|[nN][oO])
				;;
			    *)
				$printcmd -P $printer $tempdir/file.txt
				;;
			esac
		    fi
		fi
	    fi
	fi
	;;
esac

echo
read -p "Use YubiKey with Challenge-Response (Y/n): " R
case $R in
    n|N|[nN][oO])
	CHALRESP=0
	if [ $STATICPW -eq 0 ] ; then
	    echo "At least one unlock method is needed, exiting."
	    cleanup_all
	    exit 1
	fi
	;;
    *)
	if ! which ykchalresp >/dev/null 2>&1 ; then
	    echo "This script needs 'ykinfo' and 'ykchalresp' command (Debian package: yubikey-personalization), exiting."
	    unset PW1
	    cleanup_all
	    exit 1
	fi

	# Similar code exists in luks-functions, in do_yubikey()
	capture_outputs Ry Ey ykinfo -q -${YKSLOT} ; RC=$?
	if [ $RC -eq 0 ] && [ $Ry -eq 1 ]; then
	    [ $DEBUG -gt 0 ] && echo "Found attached YubiKey, will try challenge-response."
	elif [ $RC -eq 0 ] && [ $Ry -eq 0 ]; then
	    echo "YubiKey found but slot ${YKSLOT} not configured."
	    unset PW1
	    cleanup_all
	    exit 2
	elif [ "x${Ey}" == "xUSB error: Access denied (insufficient permissions)" ]; then
	    echo -e "${Ey}.\nCreate an udev role for yubikey."
	    unset PW1
	    cleanup_all
	    exit 4
	else
	    echo "${Ey}."
	    unset PW1
	    cleanup_all
	    exit 3
	fi

	CHALRESP=1
	echo "Challenge passphrase should be at least 10 characters."
	read -s -p "Enter challenge: " pph1 ; echo
	read -s -p "Enter again:     " pph2 ; echo
	if [ "$pph1" != "$pph2" ]; then
	    echo "Challenges do not match, try again."
	    read -s -p "Enter challenge: " pph1 ; echo
	    read -s -p "Enter again:     " pph2 ; echo
	    if [ "$pph1" != "$pph2" ]; then
		echo "Challenges do not match, exiting."
		unset pph1 ; unset pph2 ; unset PW1
		cleanup_all
		exit 1
	    fi
	fi
	unset pph2
	if [ ${#pph1} -lt 10 ] ; then
	    echo "Wrong length of challenge (should be at least 10 characters): ${#pph1}"
	    read -s -p "Enter challenge: " pph1 ; echo
	    read -s -p "Enter again:     " pph2 ; echo
	    if [ "$pph1" != "$pph2" ]; then
		echo "Challenges do not match, exiting."
		unset pph1 ; unset pph2 ; unset PW1
		cleanup_all
		exit 1
	    fi
	    unset pph2
	    if [ ${#pph1} -lt 10 ] ; then
		echo "Wrong length again, exiting."
		unset pph1 ; unset PW1
		cleanup_all
		exit 1
	    fi
	fi

	[ $DEBUG -gt 0 ] && echo -e "\nChallenge passphrase: $pph1"
	[ $HASH -gt 0 ] && pph1=$(printf %s "$pph1" | sha256sum | awk '{print $1}')
	[ $DEBUG -gt 0 ] && [ $HASH -gt 0 ] && echo "Hash: $pph1"
	echo -e "\nSending challenge to YubiKey, press button if blinking."
	Resp="$(ykchalresp -${YKSLOT} "$pph1" || true )"
	if [ -z "$Resp" ] ; then
	    echo "Yubikey not available, wrong config (slot ${YKSLOT}) or timed out waiting for button press."
	    unset pph1 ; unset Resp ; unset PW1
	    cleanup_all
	    exit 1
	fi
	[ $DEBUG -gt 0 ] && echo -e "\nResponse:     $Resp"
	if [ $CONCATENATE -gt 0 ] ; then
	    Resp=${pph1}${Resp}
	    [ $DEBUG -gt 0 ] && echo "Concatenated: $Resp"
	fi
	unset pph1
	;;
esac

if [ $PHYSDEV -gt 0 ] ; then
    luksdev=$volume
    lukslabel="luks-$label"
else
    [ $DEBUG -gt 0 ] && echo -e "\nSetting up loopback device."
    R=$( setup_loopdevice "${volume}" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "$R" ; exit $RC
    fi
    read loop_before loopdev <<<$( IFS=":"; echo $R )
    DEBUG_loopdev[0]="Image file attached to loop device: ${loopdev}"
    DEBUG_loopdev[1]="Image file already attached to ${loopdev}"
    [ $DEBUG -gt 0 ] && echo "${DEBUG_loopdev[$loop_before]}"
    luksdev=$loopdev
    lukslabel="luks_img-$volume"
fi

echo -e "\nCreating LUKS volume."
if [ $STATICPW -gt 0 ] ; then
    echo "$PW1" > $tempdir/args.txt
    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
    # The first arg to 'printf' should be without '\n' otherwise the password will include NEWLINE
    $SUCMD "printf '%s' \"$( cat $tempdir/args.txt )\" | cryptsetup --label $lukslabel --key-file - luksFormat $luksdev" ; RC=$?
    [ $RC -eq 1 ] && echo -n "Something went wrong, did you miss to write 'yes' in uppercase?"
    if [ $RC -gt 0 ] ; then
	echo -e "\nCould not create LUKS volume, exiting."
	unset Resp ; unset PW1
	if [ $PHYSDEV -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	    R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	    [ $RC2 -gt 0 ] && echo "$R"
	fi
	cleanup_all
	exit $RC
    fi
    if [ $CHALRESP -gt 0 ] ; then
	echo -e "\nAdding Challenge-Response to LUKS volume."
	#echo "$Resp" >> $tempdir/args.txt
	#echo "$Resp" >> $tempdir/args.txt
	if [ ! -z $SLOT ] && [ $SLOT -gt 0 ] ; then
	    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
	    #$SUCMD "printf '%s\n' \"$( cat $tempdir/args.txt )\" | cryptsetup --key-slot=$SLOT luksAddKey $luksdev" ; RC=$?
	    # The following should work from 2.1.0, works at least with 2.6.1
	    $SUCMD "cryptsetup --key-slot=$SLOT --key-file <( echo -n "$PW1" ) luksAddKey $luksdev <( echo -n "$Resp" )" ; RC=$?
	else
	    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
	    #$SUCMD "printf '%s\n' \"$( cat $tempdir/args.txt )\" | cryptsetup luksAddKey $luksdev" ; RC=$?
	    # The following should work from 2.1.0, works at least with 2.6.1
	    $SUCMD "cryptsetup --key-file <( echo -n "$PW1" ) luksAddKey $luksdev <( echo -n "$Resp" )" ; RC=$?
	fi
    fi
    # Not using 'unlock_volume()' in luks-functions as we know the password
    [ $DEBUG -gt 0 ] && echo -e "\nUnlocking LUKS volume."
    [ $DEBUG -gt 0 ] && echo "Sleeping 2 seconds to allow the device to settle."
    sleep 2s
    R=$( udisksctl unlock -b $luksdev --key-file <( echo -n "$PW1" ) 2>&1 ) ; RC=$?
    unset PW1 ; unset Resp
    if [ $RC -gt 0 ] ; then
	echo "Unlock failed: $R"
	if [ $PHYSDEV -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	    R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	    [ $RC2 -gt 0 ] && echo "$R"
	fi
	cleanup_all
	exit $RC
    fi
else
    echo "$Resp" > $tempdir/args.txt
    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
    # The first arg to 'printf' should be without '\n' otherwise the password will include NEWLINE
    $SUCMD "printf '%s' \"$( cat $tempdir/args.txt )\" | cryptsetup --label $lukslabel --key-file - luksFormat $luksdev" ; RC=$?
    [ $RC -eq 1 ] && echo -n "Something went wrong, did you miss to write 'yes' in uppercase?"
    if [ $RC -gt 0 ] ; then
	echo -e "\nCould not create LUKS volume, exiting."
	unset Resp
	if [ $PHYSDEV -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	    R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
            [ $RC2 -gt 0 ] && echo "$R"
	fi
	cleanup_all
	exit $RC
    fi
    # Not using 'unlock_volume()' in luks-functions as we know the Challenge-Response
    [ $DEBUG -gt 0 ] && echo -e "\nUnlocking LUKS volume."
    R=$( udisksctl unlock -b $luksdev --key-file <( echo -n "$Resp" ) 2>&1 ) ; RC=$?
    unset Resp
fi
$rmcmd $tempdir/args.txt
[ $RC -gt 0 ] && exit $RC   # unlock failed...
fsdev=$( echo $R | sed -e 's/.* as //' | sed -e 's/\.$//' )
[ $DEBUG -gt 0 ] && echo "Filesystem dev: ${fsdev}"
echo

echo "Creating filesystem in LUKS volume."
echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
R=$( $SUCMD "mke2fs -t ext4 -L $label $fsdev 2>&1" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo -e "\nSomething went wrong with 'mke2fs':"
    echo "Output from mke2fs (newlines stipped off):"
    echo $R
    echo
    [ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
    R=$( lock_volume "${luksdev}" ) ; RC2=$?
    [ $RC2 -gt 0 ] && echo "$R"
    if [ $PHYSDEV -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	[ $RC2 -gt 0 ] && echo "$R"
    fi
    cleanup_all
    exit $RC
fi
echo    

# Time to mount filesystem
# Code with more error handling in luksextend.sh, luksmount.sh
echo "Mounting filesystem."
[ $DEBUG -gt 0 ] && echo "Sleeping 2 seconds to allow the device to settle."
sleep 2
R=$( udisksctl mount -b $fsdev ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo -e "\nSomething went wrong with mount of filesystem:"
    echo "$R"
    echo
    if [ $fsdev_before -eq 0 ] ; then
	[ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
	R=$( lock_volume "${luksdev}" ) ; RC2=$?
	if [ $RC2 -gt 0 ] ; then
	    echo "$R"
	fi
    fi
    if [ $PHYSDEV -eq 0 ] && [ $loop_before -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	if [ $RC2 -gt 0 ] ; then
	    echo "$R" ; exit $RC2
	fi
    fi
    exit $RC
fi
filesys=$( echo $R | sed -e 's/.* at //' | sed -e 's/\.$//' )
echo "Filesystem mounted at ${filesys}"
echo

myUID=$( id -u ) ; myGID=$( id -g )
echo "Changing user/group of newly created filesystem's root"
echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
$SUCMD "chown $myUID:$myGID ${filesys}/."

if [ $PRINTFILE -gt 0 ] ; then
    read -p "Keep or cleanout ${tempdir} with static password file (k/C): " R
    case $R in
	k|K|[kK][eE][eE][pP])
	;;
	*)
	    cleanup_tmp
	    ;;
    esac
fi

echo "Done!"
echo
