#!/bin/bash
# bash is needed to use 'read' command that has silent mode to not echo passphrase
#
# Version 1.1 Copyright (c) Magnus (Mem) Sandberg 2019
# Email: mem (a) datakon , se
#
# Created by Mem, 2019-05-29
#
# Inspired by 'yubikey-luks-enroll' from yubikey-luks, https://github.com/cornelinux/yubikey-luks
# Also inspired by my own 'tcmount' script for mount TrueCrypt volumes
#
# Developed for udisks2 2.8.1-4 (Debian 10.x Buster)
#
# Depends Debian packages:    socat, udisks2, yubikey-personalization (need when using YubiKey)
# Recommends Debian packages: a2ps
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
DEBUG=0
PRINTOUT=0

[ -f $CONFIG ] && . $CONFIG

if [ "x$1" = "x-v" ] ; then
    DEBUG=1
    shift
fi

if [ "x$1" = "x" ] || [ "x$1" = "x-h" ] ; then
    echo
    echo "Usage: $0 [-h] [-v] <volume>"
    echo
    echo " -h      : show this help text"
    echo " -v      : verbose mode"
    echo
    echo "<volume> : the volume filename to be created, with or without '.img' extension"
    echo "         : volume will be created in ${IMAGEPATH}/"
    echo "         :"
    echo "         :To change path, edit ${CONFIG}"
    echo
    exit
fi

if ! which udisksctl >/dev/null 2>&1 ; then
    echo "This script needs 'udisksctl' command (Debian package: udisks2), exiting."
    exit 1
fi

if ! which socat >/dev/null 2>&1 ; then
    echo "This script needs 'socat' command (Debian package: socat), exiting."
    exit 1
fi

cleanup_tmp () {
    if [ -e $tempdir ] ; then
	echo "Cleaning up $tempdir"
	[ $DEBUG -gt 0 ] && echo "Using '${rmcmd}' to remove files"
	$rmcmd 2>/dev/null $tempdir/*.txt
	rmdir $tempdir
    fi
}

volume=$1
volume=$( echo $volume | sed -e 's/\.img$//' )
if [ -f ${IMAGEPATH}/${volume}.img ] ; then
    echo "Volume ${IMAGEPATH}/${volume}.img already exists."
    exit 1
fi

if which shred >/dev/null 2>&1 ; then
    rmcmd="shred --remove --zero"
elif which wipe >/dev/null 2>&1 ; then
    rmcmd="wipe"
else
    rmcmd="rm"
fi

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
echo "\$IMAGEPATH=\"${IMAGEPATH}\""
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

I use '-ochal-btn-trig' to prevent other scripts or users at the same
computer to use the YubiKey without the need to press the YubiKey button.

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

echo "Setting up LUKS volume in image file ${IMAGEPATH}/${volume}.img"
read -p "Enter image size in 'dd' format (512M, 1G, etc): " R
if [ $SPARSE -gt 0 ] ; then
    # Using 'if [[ ]]' as case statements doesn't do regex
    if [[ "$R" =~  ^[0-9]+$ ]] ||
      [[ "$R" =~ ^[0-9]+c$ ]] ||
      [[ "$R" =~ ^[0-9]+w$ ]] ||
      [[ "$R" =~ ^[0-9]+b$ ]] ||
      [[ "$R" =~ ^[0-9]+[kMGTPEZY]B$ ]] ||
      [[ "$R" =~ ^[0-9]+[KMGTPEZY]$ ]] ; then
	BS=1
    else
	echo "Unknown size value for 'dd': $R"
	cleanup_tmp
	exit 1
    fi
    [ $DEBUG -gt 0 ] && echo "Block size for dd: $BS"
    [ $DEBUG -gt 0 ] && echo "Number of blocks to create: $R"

    if [ $DEBUG -gt 0 ] ; then
	dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=0 seek=$R
    else
	dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=0 seek=$R 2>&1 | egrep -v ' records | copied, '
    fi
else
    # Using 'if [[ ]]' as case statements doesn't do regex
    if [[ "$R" =~  ^[0-9]+$ ]] ||
      [[ "$R" =~ ^[0-9]+c$ ]] ||
      [[ "$R" =~ ^[0-9]+w$ ]] ; then
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

echo
echo "Select preferred mount-name, usually mounted under /media/$USER/, like /media/$USER/$volume"
echo "The mount-name can be changed by root with"
echo "'tune2fs -L <new-name> <dev>' where <dev> usually is something like /dev/dm-X."
read -p "Enter mount-name (default: $volume): " label
[ -z $label ] && label=$volume

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
		;;
	    *)
		PRINTOUT=1
		echo "Date: $(date +%Y-%m-%d)" > $tempdir/file.txt
		chmod 600 $tempdir/file.txt
		echo "LUKS image: $(hostname -s):${IMAGEPATH}/${volume}.img" >> $tempdir/file.txt
		echo "" >> $tempdir/file.txt
		;;
	esac

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
			rm ${IMAGEPATH}/${volume}.img
			cleanup_tmp
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
			rm ${IMAGEPATH}/${volume}.img
			cleanup_tmp
			exit 1
		    fi
		    unset PW2
		    if [ ${#PW1} -lt 10 ] || [ ${#PW1} -gt 99 ] ; then
			echo "Wrong length again, exiting."
			unset PW1
			rm ${IMAGEPATH}/${volume}.img
			cleanup_tmp
			exit 1
		    fi
		fi
		;;
	    *)
		AUTOGEN=1
		read -p "Enter password length to create, allowed 10-99 characters (default 32): " R
		case $R in
		    [0-9][0-9])
			PWLEN=$R
			;;
		    '')
			PWLEN=32
			;;
		    *)
			echo "Wrong value: $R"
			rm ${IMAGEPATH}/${volume}.img
			cleanup_tmp
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
	[ $DEBUG -gt 0 ] && echo -e "\nPassword: $PW1"

	if [ $PRINTOUT -gt 0 ] ; then
	    echo "Password: $PW1" >> $tempdir/file.txt
	    echo
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
			    rm ${IMAGEPATH}/${volume}.img
			    cleanup_tmp
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
			    printcmd="a2ps -q -1Rl80"
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
	;;
esac

echo
read -p "Use YubiKey with Challenge-Response (Y/n): " R
case $R in
    n|N|[nN][oO])
	CHALRESP=0
	if [ $STATICPW -eq 0 ] ; then
	    echo "At least one unlock method is needed, exiting."
	    rm ${IMAGEPATH}/${volume}.img
	    cleanup_tmp
	    exit 1
	fi
	;;
    *)
	if ! which ykchalresp >/dev/null 2>&1 ; then
	    echo "This script needs 'ykchalresp' command (Debian package: yubikey-personalization), exiting."
	    unset PW1
	    rm ${IMAGEPATH}/${volume}.img
	    cleanup_tmp
	    exit 1
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
		rm ${IMAGEPATH}/${volume}.img
		cleanup_tmp
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
		rm ${IMAGEPATH}/${volume}.img
		cleanup_tmp
		exit 1
	    fi
	    unset pph2
	    if [ ${#pph1} -lt 10 ] ; then
		echo "Wrong length again, exiting."
		unset pph1 ; unset PW1
		rm ${IMAGEPATH}/${volume}.img
		cleanup_tmp
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
	    rm ${IMAGEPATH}/${volume}.img
	    cleanup_tmp
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

[ $DEBUG -gt 0 ] && echo -e "\nSetting up loopback device"
R=$( udisksctl loop-setup -f ${IMAGEPATH}/${volume}.img ) ; RC=$?
[ $RC -gt 0 ] && exit $RC
loopdev=$( echo $R | sed -e 's/.* as //' | sed -e 's/\.$//' )
[ $DEBUG -gt 0 ] && echo "Loop dev: ${loopdev}."

echo -e "\nCreating LUKS volume."
if [ $STATICPW -gt 0 ] ; then
    echo "$PW1" > $tempdir/args.txt
    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
    # The first arg to 'printf' should be without '\n' otherwise the password will include NEWLINE
    $SUCMD "printf '%s' \"$( cat $tempdir/args.txt )\" | cryptsetup --label luks_img-$volume --key-file - luksFormat $loopdev" ; RC=$?
    [ $RC -eq 1 ] && echo -n "Something went wrong, did you miss to write 'yes' in uppercase?"
    if [ $RC -gt 0 ] ; then
	echo -e "\nCould not create LUKS volume, exiting."
	[ $DEBUG -gt 0 ] && echo "Tear down loop device."
	udisksctl loop-delete -b $loopdev
	unset Resp ; unset PW1
	rm ${IMAGEPATH}/${volume}.img
	cleanup_tmp
	exit $RC
    fi
    if [ $CHALRESP -gt 0 ] ; then
	echo -e "\nAdding Challenge-Response to LUKS volume."
	echo "$Resp" >> $tempdir/args.txt
	echo "$Resp" >> $tempdir/args.txt
	if [ ! -z $SLOT ] && [ $SLOT -gt 0 ] ; then
	    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
	    $SUCMD "printf '%s\n' \"$( cat $tempdir/args.txt )\" | cryptsetup --key-slot=$SLOT luksAddKey $loopdev" ; RC=$?
	else
	    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
	    $SUCMD "printf '%s\n' \"$( cat $tempdir/args.txt )\" | cryptsetup luksAddKey $loopdev" ; RC=$?
	fi
    fi
    [ $DEBUG -gt 0 ] && echo -e "\nUnlocking LUKS volume."
    R=$( (sleep 2; echo "$PW1"; sleep 5) | socat - EXEC:"udisksctl unlock -b $loopdev",pty,setsid,ctty ) ; RC=$?
    R=$( echo $R | sed -e 's/\r$//' ) # as socat adds trailing <CR>
    unset PW1 ; unset Resp
else
    echo "$Resp" > $tempdir/args.txt
    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
    # The first arg to 'printf' should be without '\n' otherwise the password will include NEWLINE
    $SUCMD "printf '%s' \"$( cat $tempdir/args.txt )\" | cryptsetup --label luks_img-$volume --key-file - luksFormat $loopdev" ; RC=$?
    [ $RC -eq 1 ] && echo -n "Something went wrong, did you miss to write 'yes' in uppercase?"
    if [ $RC -gt 0 ] ; then
	echo -e "\nCould not create LUKS volume, exiting."
	[ $DEBUG -gt 0 ] && echo "Tear down loop device."
	udisksctl loop-delete -b $loopdev
	unset Resp
	rm ${IMAGEPATH}/${volume}.img
	cleanup_tmp
	exit $RC
    fi
    [ $DEBUG -gt 0 ] && echo -e "\nUnlocking LUKS volume."
    R=$( (sleep 2; echo "$Resp"; sleep 5) | socat - EXEC:"udisksctl unlock -b $loopdev",pty,setsid,ctty ) ; RC=$?
    R=$( echo $R | sed -e 's/\r$//' ) # as socat adds trailing <CR>
    unset Resp
fi
$rmcmd $tempdir/args.txt
[ $RC -gt 0 ] && exit $RC   # unlock failed...
fsdev=$( echo $R | sed -e 's/.* as //' | sed -e 's/\.$//' )
[ $DEBUG -gt 0 ] && echo "Filesystem dev: ${fsdev}."
echo

echo "Creating filesystem in LUKS volume."
echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
R=$( $SUCMD "mke2fs -t ext4 -L $label $fsdev 2>&1" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo -e "\nSomething went wrong with 'mke2fs':"
    echo "Output from mke2fs (newlines stipped off):"
    echo $R
    echo
    udisksctl lock -b $loopdev
    udisksctl loop-delete -b $loopdev
    cleanup_tmp
    exit $RC
fi
echo    

echo "Mounting filesystem."
R=$( udisksctl mount -b $fsdev ) ; RC=$?
[ $RC -gt 0 ] && exit $RC
filesys=$( echo $R | sed -e 's/.* at //' | sed -e 's/\.$//' )
echo "Filesystem mounted at ${filesys}"
echo

myUID=$( id -u ) ; myGID=$( id -g )
echo "Changing user/group of newly created filesystem's root"
echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
$SUCMD "chown $myUID:$myGID ${filesys}/."

if [ $PRINTOUT -gt 0 ] ; then
    read -p "Keep or cleanout ${tempdir} (k/C): " R
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
