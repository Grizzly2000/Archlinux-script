#!/bin/sh

#set -x 

##############################################################################################################################
# Variable declaration                                                                                                       #
##############################################################################################################################

DEVICE_NAME="/dev/sda"									# Install ArchLinux on this device
DEVICE_NAME_SHORT=${DEVICE_NAME##*/}					# get 'sdaX'
HOSTNAME_ARCH="ordinateur"								# Computer name
USERNAME="utilisateur"									# Sudoer username
KEYBOARD_LAYOUT="fr"									# Keyboard Layout

LVM_NAME="ArchLVM"										# Logical Volume Manager (LVM) label
ARG_GRUB="cryptdevice=\/dev\/sda3:${LVM_NAME}"			# Grub argument for grub.cfg
SCRIPT_PATH="$(dirname "$(readlink -f "$0")")/$0"		# Script path


##############################################################################################################################
# Show ArchLinux configuration                                                                                               #
##############################################################################################################################

cat << EOF
###################################################

		ArchLinux Installer

###################################################

[i] ArchLinux Installation - Script information

	This script allows to install Archlinux on UEFI System (do not forget to configure your motherboard).
	It will destroy all your data stored in this device : ${DEVICE_NAME}.
	You have to launch this script from an Archlinux CD Live.

[i] - Partitions (LVM on LUKS with GPT) :

	${DEVICE_NAME_SHORT}
	 ├─${DEVICE_NAME_SHORT}1				/boot			200M
	 ├─${DEVICE_NAME_SHORT}2				/boot/efi		550M
	 └─${DEVICE_NAME_SHORT}3 		
	   └─cryptolvm
	     ├─${LVM_NAME}-swap		swap 			4G
	     └─${LVM_NAME}-root		/			-

[i] - Cryptsetup options :

	Cypher 				: aes-xts-plain64
	key size 			: 512
	Hash used 			: sha512
	Milliseconds spend with PBKDF 	: 5000
	Random used 			: /dev/random

[i] - System configuration

	Install on device 	: ${DEVICE_NAME}
	LVM Name 		: ${LVM_NAME}
	Keyboard layout 	: ${KEYBOARD_LAYOUT}
	Hostname 		: ${HOSTNAME_ARCH}
	Username (sudoer) 	: ${USERNAME}

[i] - Package installation

	archlinux base 	: base base-devel 
	grub stuff 	: efibootmgr grub grub-efi-x86_64 
	network stuff 	: dhclient dialog wpa_supplicant wget
	sysadmin stuff 	: zsh git vim screen htop

EOF

# Check root
if [ "$(/usr/bin/id -u)" != "0" ]
then
	echo "This script must be run with root privileges."
	exit
fi

# Get user confirmation
echo -ne "Are you sure you wish to continue the installation of Archlinux?\nType : 'run_archlinux_installation' to confirm.\n>"
read REPLY
if [ "$REPLY" != "run_archlinux_installation" ]; then
	echo '[!] Bad confirmation.'
	echo '	Abort ArchLinux installation.'
	exit
fi


##############################################################################################################################
# Requierement for the installation                                                                                          #
##############################################################################################################################

# Check connectivity
curl -sSf microsoft.com > /dev/nul && echo 'Connectivity OK' || { echo 'Error : No internet' && exit; }

# Enable NTP
timedatectl set-ntp true

# Load kernel modules for encryption
modprobe -a dm-mod dm_crypt


##############################################################################################################################
# Disk Configuration (Partition, Formatting, mount)                                                                          #
##############################################################################################################################

# Create partition describe below
sgdisk --zap-all /dev/sda
sgdisk -Z ${DEVICE_NAME}
sgdisk -n 0:0:+200M -t 0:EF02 -c 0:"boot_bios" ${DEVICE_NAME}
sgdisk -n 0:0:+550M -t 0:8300 -c 0:"boot_efi" ${DEVICE_NAME}
sgdisk -n 0:0:0 -t 0:8E00 -c 0:"cryptolvm" ${DEVICE_NAME}
sgdisk -p ${DEVICE_NAME}

# LUKS
cryptsetup -v -y -c aes-xts-plain64 -s 512 -h sha512 -i 5000 --use-random luksFormat ${DEVICE_NAME}3 --batch-mode
cryptsetup open ${DEVICE_NAME}3 cryptolvm

# LVM (root + swap)
pvcreate /dev/mapper/cryptolvm
vgcreate ${LVM_NAME} /dev/mapper/cryptolvm
lvcreate -L 4G ${LVM_NAME} -n swap
lvcreate -l 100%FREE ${LVM_NAME} -n root

# Format FS
mkfs.ext4 ${DEVICE_NAME}1				# /boot
mkfs.vfat -F32 ${DEVICE_NAME}2			# /boot/efi
mkfs.ext4 /dev/${LVM_NAME}/root 		# /
mkswap /dev/${LVM_NAME}/swap 			# swap

# Mount FS
mount /dev/${LVM_NAME}/root /mnt
mkdir -p /mnt/boot
mount ${DEVICE_NAME}1 /mnt/boot
mkdir -p /mnt/boot/efi
mount -t vfat ${DEVICE_NAME}2 /mnt/boot/efi
mkdir -p /mnt/boot/efi/EFI
swapon /dev/${LVM_NAME}/swap


##############################################################################################################################
# Package Installation                                                                                                       #
##############################################################################################################################

# Install package
curl "https://www.archlinux.org/mirrorlist/?country=FR&protocol=http&protocol=https&ip_version=4" | sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist
pacstrap /mnt base base-devel 
pacstrap /mnt efibootmgr grub grub-efi-x86_64 
pacstrap /mnt dhclient dialog wpa_supplicant wget
pacstrap /mnt zsh git vim screen htop

# Generate fstab
genfstab -U -p /mnt >> /mnt/etc/fstab


##############################################################################################################################
# Arch-chroot stage                                                                                                          #
##############################################################################################################################

cat <<EOF > /mnt/root/arch2.sh

# Set .zshrc in root directory
wget -O /root/.zshrc https://git.grml.org/f/grml-etc-core/etc/zsh/zshrc

# Set root password
echo "[+] Changer le mot de passe root"
passwd
chsh -s /usr/bin/zsh

# Set Hostname
echo $HOSTNAME_ARCH > /etc/hostname
echo '127.0.1.1 $HOSTNAME_ARCH.localdomain $HOSTNAME_ARCH' >> /etc/hosts

# Set time, language and keyboard layout
rm /etc/localtime
ln -s /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > locale.conf
echo "KEYMAP=$KEYBOARD_LAYOUT" > /etc/vconsole.conf 

# Initramfs
sed -i 's/^HOOKS.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block lvm2 encrypt filesystems fsck)/g' /etc/mkinitcpio.conf
mkinitcpio -p linux

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch 
sed -i "s/GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"${ARG_GRUB}\"/" /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Add user
useradd -m -g users -G wheel -s /usr/bin/zsh "${USERNAME}"
sed -i '/%wheel ALL=(ALL) ALL/s/^#//g' /etc/sudoers
cp /root/.zshrc "/home/${USERNAME}/"
echo "[+] Changer le mot de passe user"
passwd "${USERNAME}"

# IRONKEY Module sg
echo "# Load SG module for IRONKEY\nsg" > /etc/modules-load.d/sg.conf

exit

EOF

# Execute stage 2 (chroot /mnt)
chmod +x /mnt/root/arch2.sh
arch-chroot /mnt /root/arch2.sh


##############################################################################################################################
# Clean up installation                                                                                                      #
##############################################################################################################################

# Remove installation script
rm ${SCRIPT_PATH}
rm /mnt/root/arch2.sh

# Umount & reboot
umount -R /mnt
reboot
