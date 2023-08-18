#!/bin/bash

# We use a public/private keypair to authenticate. 
# Surgeon uses the 169.254.8.X subnet to differentiate itself from
# a fully booted system for safety purposes.
SSH="ssh root@169.254.8.1"

show_warning () {
  echo "Leapster flash utility - installs a custom OS on your leapster!"
  echo
  echo "WARNING! This utility will ERASE the stock leapster OS and any other"
  echo "data on the device. The device can be restored to stock settings using"
  echo "the LeapFrog Connect app. Note that flashing your device will likely"
  echo "VOID YOUR WARRANTY! Proceed at your own risk."
  echo
  echo "Please power off your leapster, hold the L + R shoulder buttons (LeapsterGS), "
  echo "or right arrow + home buttons (LeapPad2), and then press power."
  echo "You should see a screen with a green background."

  read -p "Press enter when you're ready to continue."
}

show_machinelist () {
  echo "----------------------------------------------------------------"
  echo "What type of system would you like to flash?"
  echo
  echo "1. LF1000-Didj (Didj with EmeraldBoot)"
  echo "2. LF1000 (Leapster Explorer)"
  echo "3. LF2000 (Leapster GS, LeapPad 2, LeapPad Ultra XDI)"
  echo "4. [EXPERIMENTAL] LF2000 w/ RT+OC Kernel (Leapster GS, LeapPad 2, LeapPad Ultra XDI)"
  echo "5. LF3000 (LeapPad 3, LeapPad Platinum)"
  echo "6. [Advanced] open developer options"
}

show_dev_options () {
  echo "----------------------------------------------------------------"
  echo "What option are you looking for?"
  echo 
  echo "1. Boot into surgeon"
  echo "2. Flash kernel only"
  echo "3. Fkash Root file system only"
}

show_device_list () {
  echo "----------------------------------------------------------------"
  echo "What type of system are you working on?"
  echo
  echo "1. LF1000-Didj (Didj with EmeraldBoot)"
  echo "2. LF1000 (Leapster Explorer)"
  echo "3. LF2000 (Leapster GS, LeapPad 2, LeapPad Ultra XDI)"
  echo "4. LF2000 w/ RT+OC Kernel (Leapster GS, LeapPad 2, LeapPad Ultra XDI)"
  echo "5. LF3000 (LeapPad 3, LeapPad Platinum)"
}

boot_surgeon () {
  surgeon_path=$1
  memloc=$2
  echo "Booting the Surgeon environment..."
  python2 make_cbf.py $memloc $surgeon_path surgeon_tmp.cbf
  sudo python2 boot_surgeon.py surgeon_tmp.cbf
  echo -n "Done! Waiting for Surgeon to come up..."
  rm surgeon_tmp.cbf
  sleep 15
  echo "Done!"
}

nand_part_detect () {
  # Probe for filesystem partition locations, they can vary based on kernel version + presence of NOR flash drivers.
  # TODO: Make the escaping less yucky...
  KERNEL_PARTITION=`${SSH} "awk -e '\\$4 ~ /\"Kernel\"/ {print \"/dev/\" substr(\\$1, 1, length(\\$1)-1)}' /proc/mtd"`
  RFS_PARTITION=`${SSH} "awk -e '\\$4 ~ /\"RFS\"/ {print \"/dev/\" substr(\\$1, 1, length(\\$1)-1)}' /proc/mtd"`
  echo "Detected Kernel partition=$KERNEL_PARTITION RFS Partition=$RFS_PARTITION"
}

nand_flash_kernel () {
  kernel_path=$1
  echo -n "Flashing the kernel..."
  ${SSH} "/usr/sbin/flash_erase $KERNEL_PARTITION 0 0"
  cat $kernel_path | ${SSH} "/usr/sbin/nandwrite -p $KERNEL_PARTITION -"
  echo "Done flashing the kernel!"
}

nand_flash_rfs () {
  rfs_path=$1
  echo -n "Flashing the root filesystem..."
  ${SSH} "/usr/sbin/ubiformat -y $RFS_PARTITION"
  ${SSH} "/usr/sbin/ubiattach -p $RFS_PARTITION"
  sleep 1
  ${SSH} "/usr/sbin/ubimkvol /dev/ubi0 -N RFS -m"
  sleep 1
  ${SSH} "mount -t ubifs /dev/ubi0_0 /mnt/root"
  # Note: We used to use a ubifs image here, but now use a .tar.gz.
  # This removes the need to care about PEB/LEB sizes at build time,
  # which is important as some LF2000 models (Ultra XDi) have differing sizes.
  echo "Writing rootfs image..."  
  cat $rfs_path | ${SSH} "gunzip -c | tar x -f '-' -C /mnt/root"
  ${SSH} "umount /mnt/root"
  ${SSH} '/usr/sbin/ubidetach -d 0'
  sleep 3
  echo "Done flashing the root filesystem!"
}

nand_maybe_wipe_roms () {
  read -p "Do you want to format the roms partition? (You should do this on the first flash of retroleap) (y/n)" -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]
  then
    ${SSH} /usr/sbin/ubiformat /dev/mtd3
    ${SSH} /usr/sbin/ubiattach -p /dev/mtd3
    ${SSH} /usr/sbin/ubimkvol /dev/ubi0 -m -N roms
  fi
}

flash_nand () {
  prefix=$1
  if [[ $prefix == lf1000_* ]]; then
	  memloc="high"
	  kernel="zImage_tmp.cbf"
	  python2 make_cbf.py $memloc ${prefix}zImage $kernel
  else
	  memloc="superhigh"
	  kernel=${prefix}uImage
  fi
  boot_surgeon ${prefix}surgeon_zImage $memloc
  # For the first ssh command, skip hostkey checking to avoid prompting the user.
  ${SSH} -o "StrictHostKeyChecking no" 'test'
  nand_part_detect
  nand_flash_kernel $kernel
  nand_flash_rfs ${prefix}rootfs.tar.gz
  nand_maybe_wipe_roms 
  echo "Done! Rebooting the host."
  ${SSH} '/sbin/reboot'
}

mmc_flash_kernel () {
  kernel_path=$1
  echo -n "Flashing the kernel..."
  # TODO: This directory structure should be included in surgeon images.
  ${SSH} "mkdir /mnt/boot"
  # TODO: This assumes a specific partition layout - not sure if this is the case for all devices?
  ${SSH} "mount /dev/mmcblk0p2 /mnt/boot"
  cat $kernel_path | ${SSH} "cat - > /mnt/boot/uImage"
  ${SSH} "umount /dev/mmcblk0p2"
  echo "Done flashing the kernel!"
}

mmc_flash_rfs () {
  rfs_path=$1
  # Size of the rootfs to be flashed, in bytes.
  echo -n "Flashing the root filesystem..."
  ${SSH} "/sbin/mkfs.ext4 -F -L RFS -O ^metadata_csum /dev/mmcblk0p3"
  # TODO: This directory structure should be included in surgeon images.
  ${SSH} "mkdir /mnt/root"
  ${SSH} "mount -t ext4 /dev/mmcblk0p3 /mnt/root"
  echo "Writing rootfs image..."  
  cat $rfs_path | ${SSH} "gunzip -c | tar x -f '-' -C /mnt/root"
  ${SSH} "umount /mnt/root"
  echo "Done flashing the root filesystem!"
}

flash_mmc () {
  prefix=$1
  boot_surgeon ${prefix}surgeon_zImage superhigh
  # For the first ssh command, skip hostkey checking to avoid prompting the user.
  ${SSH} -o "StrictHostKeyChecking no" 'test'
  mmc_flash_kernel ${prefix}uImage
  mmc_flash_rfs ${prefix}rootfs.tar.gz
  echo "Done! Rebooting the host."
  sleep 3
  ${SSH} '/sbin/reboot'
}

developer_options () {
  show_dev_options
  read -p "Enter choice (1 - 3)" menuopt
  case $menuopt in
    1) devop="surgeon" ;;
    2) devop="kernel" ;;
    3) devop="rootfs" ;;
    *) echo -e "Unknown choice!" && sleep 2
  esac

  show_device_list
  read -p "Enter choice (1 - 5)" deviceopt
  case $deviceopt in 
    1) prefix="lf1000_didj_" ;;
    2) prefix="lf1000_" ;;
    3) prefix="lf2000_" ;;
    4) prefix="lf2000_rt_" ;;
    5) prefix="lf3000_" ;;
    *) echo -e "Unknown choice!" && sleep 2
  esac

  if [ $devop == "surgeon" ]; then 
    if [ $prefix == "lf1000_*" ]; then
      boot_surgeon ${prefix}surgeon_zImage high
    else 
      boot_surgeon ${prefix}surgeon_zImage superhigh
    fi
  elif [ $devop == "kernel"]; then 
    if [ $prefix == "lf1000_*" ]; then
      kernel="zImage_tmp.cbf"
  	  python2 make_cbf.py high ${prefix}zImage $kernel
      nand_part_detect
      nand_flash_kernel $kernel
    elif [ $prefix == "lf2000_*" ]; then 
      nand_part_detect
      nand_flash_kernel ${prefix}uImage
    else 
      mmc_flash_kernel ${prefix}uImage
    fi
  else
    if [ $prefix == "lf3000" ]; then
      mmc_flash_rfs ${prefix}rootfs.tar.gz
    else 
      nand_part_detect
      nand_flash_rfs ${prefix}rootfs.tar.gz
    fi  
  fi 
}

show_warning
prefix=$1
if [ -z "$prefix" ]
then
  show_machinelist
  read -p "Enter choice (1 - 5)" choice
  case $choice in
    1) prefix="lf1000_didj_" ;;
    2) prefix="lf1000_" ;;
    3) prefix="lf2000_" ;;
    4) prefix="lf2000_rt_" ;;
    5) prefix="lf3000_" ;;
    6) prefix="" ;;
    *) echo -e "Unknown choice!" && sleep 2
  esac
fi

if [ -z "$prefix" ]; then 
  developer_options
elif [ $prefix == "lf3000_" ]; then
	flash_mmc $prefix
else
  flash_nand $prefix
fi
