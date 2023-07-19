# zfsbootmenu-clevis-load-key

## This is a load_key hook for ZFSBootMenu to automatically unlock zfsroot dataset using clevis 

### This module doesn't unlock the dataset, it just generates a key with a valid passphrase in expected place thus providing automatic dataset unlocking in main ZBM code
Requirements:
- `ZFSBootMenu` with load_key hooks support ([my fork](https://github.com/rdmitry0911/zfsbootmenu) of it is suitable)
- OTB `clevis` (full set) and optionally `dropbear` packages are embedded in zfsbootmenu
- `latchset.clevis:decrypt=yes` user property has to be added in advance to the encrypted dataset for automatic decryption
- `latchset.clevis:netconf` user property has to be added in advance to the encrypted dataset. The value of this property should be like this: "if:ip/mask:def. route:dns" Valid example: eth0:10.7.6.22/24:10.7.6.1:8.8.8.8"
  This property is used to configure network for ssh accsess to ZBM. I use this way of passing net config params to a script to avoid rebuilding of ZBM for running on another host. In case there is no need to access ZBM via ssh, this property is not needed
- `/boot` with linux and initramfs files should reside inside the encrypted dataset
- `keylocation` of the encrypted dataset should be set to file:///some/file Valid example: file:///etc/zfs/keys/rpool.key and this file should be embedded to initramfs of the target system. It is safe as initramfs  is located in encrypted /boot directory
- As far as this script will generate a temporary keyfile in ZBM, it is a good idea for a keyfile location to create a subfolder in /etc/zfs and put a keyfile there with a unique name to avoid potential conflicts with existing files in ZBM

The logic of the module is this:
- Before asking the passphrase in zfsbootmenu this module checks if the volume is eligable for automatic unlocking
- Then it trys to decrypt the passphrase stored in a special property in encrypted format. The script uses clevis and tpm2 for that
- In case of failure it asks the user for a passphrase and check if it is valid
- Then valid passphrase is stored in clear text in keylocation (in fact in RAM) and in encrypted format bound to tpm2 in a special user property latchset.clevis:jwe of the encrypted dataset for next boots
- Then module returns the control back to ZBM

 arg1: ZFS filesystem to unlock
 
 returns: 0 on success, 1 on failure
