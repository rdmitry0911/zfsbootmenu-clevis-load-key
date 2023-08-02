#!/bin/bash

###############
### clevis hook
###############

#   Requirements:
#
# - OTB clevis (full set) and optionally dropbear packages are embedded in zfsbootmenu
# - latchset.clevis:decrypt=yes user property has to be added in advance to the encrypted dataset for automatic decryption
# - latchset.clevis:netconf user property has to be added in advance to the encrypted dataset.
#   The value of this property should be like this: "if:ip/mask:def. route:dns" Valid example: "eth0:10.7.6.22/24:10.7.6.1:8.8.8.8"
#   This property is used to configure network for ssh accsess to ZBM. I use this way of passing net config params to a script to
#   avoid rebuilding of ZBM for running on another host. In case there is no need to access ZBM via ssh this property is not needed
# - latchset.clevis:dropbear user property has to be added in advance to the encrypted dataset.
#   The value of this property should be authorized key for ssh login to zfsbootmenu as a root.
#   Valid example: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhw5gGy/g9CM8PlB23Ag1RMgPfUoXu2tKELP9FIOcK4 rdmitry0911@gmail.com"
#   This property is used to configure root ssh accsess to ZBM. I use this way of passing dropbear config to avoid rebuilding of ZBM
#   for running on another host. In case there is no need to access ZBM via ssh this property is not needed
# - /boot should reside inside the encrypted dataset
# - keylocation of the encrypted dataset should be set to file:///some/file Valid example: file:///etc/zfs/keys/rpool.key and this file
#   should be embedded to initramfs of the target system. It is safe as initramfs  is located in encrypted /boot directory
# - To avoid conflicts with existing files in ZBM, it is a good idea to create a subfolder in /etc/zfs and put a keyfile there with
#   unique name
#
# The logic of the module is this:
# - Before asking the passphrase in zfsbootmenu this module checks if the volume is eligable for automatic unlocking
# - if yes, it
#       1. Trys to decrypt the passphrase stored in a special property in encrypted format. The script uses clevis and tpm2 for that
#       2. In case of failure it asks the user a passphrase and check if it is valid
#       3. Valid passphrase is stored in clear text in keylocation (in fact in RAM) and in encrypted format bound to tpm2 in a special
#          user property latchset.clevis:jwe of the encrypted dataset for next boots
# - Then module returns the control back to ZBM
#
# arg1: ZFS filesystem
# prints: nothing
# asks: passphrase
# returns: 0 on success, 1 on failure
#


get_fs_value()
{
        fs="$1"
        value=$2

        zfs get -H -ovalue "$value" "$fs" 2> /dev/null
}

reseal_data_set()
{
  read -p "We have autodecrypt flag set to on, however $1 can't be unlocked. Would you like to reseal the password [yes/no] " SRESEAL
  seq=3
  if [[ "$SRESEAL" == "yes" ]]; then
    while [[ "$seq" -gt 0 ]]
    do
      read -s -p  "Type the password, please, to unlock $1. You have $seq attempts left : " PASS
      echo -n "$PASS" | zfs load-key -n -L prompt "$1" >&2
      res=$?
      if [[ "$res" == "0" ]]; then
        seq=0
      else
        seq=$((seq - 1))
        PASS=""
      fi
    done
    echo "$PASS"
    return 0
  else
    # In fact we don't want to reseal
    echo ""
    return 1
  fi
}

load_key_clevis() {

  dataset_for_clevis_unlock="$1"
  zdebug "Processing dataset $dataset_for_clevis_unlock"

  # We need to setup network for remote access
  # We use latchset.clevis:netconf property in encrypted dataset to store net config

  if [[ ! -f /tmp/"$dataset_for_clevis_unlock"_clevis_net ]]; then # Reconfigure network and dropbear only once
    CLEVIS_NET="$(get_fs_value "${dataset_for_clevis_unlock}" "latchset.clevis:netconf")"
    if [[ "$CLEVIS_NET" != "-" ]]; then
      # We have net config. Reconfigure network
      mkdir -p "$(dirname /tmp/'$dataset_for_clevis_unlock'_clevis_net)"
      : > /tmp/"$dataset_for_clevis_unlock"_clevis_net
      IFS=':' read -r -a netconf <<< "$CLEVIS_NET"
      dev="${netconf[0]}"
      ip="${netconf[1]}"
      dr="${netconf[2]}"
      dns="${netconf[3]}"
      zdebug "Reconfigure network: dev: $dev ip: $ip default route: $dr dns: $dns"
      ip addr add "$ip" brd + dev "$dev"
      ip route add default via "$dr"
      echo "nameserver $dns" > /etc/resolv.conf
    fi
    CLEVIS_DROPBEAR="$(get_fs_value "${dataset_for_clevis_unlock}" "latchset.clevis:dropbear")"
    if [[ "$CLEVIS_DROPBEAR" != "-" ]]; then
      # We have dropbear authorize key. Put it in a right place
      zdebug "Dropbear authorize key: $CLEVIS_DROPBEAR"
      mkdir -p /root/.ssh
      echo "$CLEVIS_DROPBEAR" >> /root/.ssh/authorized_keys
    fi
  fi

  CLEVIS_CHECK="$(zfs get -H -p -o value latchset.clevis:decrypt -s local $dataset_for_clevis_unlock)"
  if [[ "$CLEVIS_CHECK" == "yes" ]]; then
    zdebug "Found dataset for clevis unlocking: $dataset_for_clevis_unlock"
    KEYLOCATION="$(get_fs_value "${dataset_for_clevis_unlock}" keylocation)" || KEYLOCATION=
    KEYFILE="${KEYLOCATION#file://}"
    if [ "${KEYLOCATION}" = "${KEYFILE}" ] || [ -z "${KEYFILE}" ]; then
        # That's not us
        zwarn "keylocation is not file while clevis unlock is set for dataset $dataset_for_clevis_unlock"
        return 0
    fi
    if [ -f "${KEYFILE}" ]; then
      zwarn "Key filename $KEYLOCATION in keylocation property for dataset $dataset_for_clevis_unlock conflicts with existing file in ZBM. Please change it"
      return 0
    fi
    # We suppose the keylocation has value in format file:///something/key
    KEYSTATUS="$(zfs get -H -p -o value keystatus -s none $dataset_for_clevis_unlock)"
    if [[ "$KEYSTATUS" == "unavailable" ]]; then
        # Prepare the key with password for unlocking in right place
        mkdir -p "$(dirname "$KEYFILE")"
        JWE="$(zfs get -H -p -o value latchset.clevis:jwe -s local "$dataset_for_clevis_unlock")"
        mkdir -p "$(dirname /tmp/"$dataset_for_clevis_unlock"_clevis_temp_key)"
        echo "$JWE" | clevis decrypt >/tmp/"$dataset_for_clevis_unlock"_clevis_temp_key
        if zfs load-key -L file:///tmp/"$dataset_for_clevis_unlock"_clevis_temp_key -n $dataset_for_clevis_unlock; then
          mv /tmp/"$dataset_for_clevis_unlock"_clevis_temp_key "$KEYFILE"
          return 0
        else
          # We have autodecrypt flag set to on, however dataset can't be unlocked. Offer resealing the password
          RESEAL="$(reseal_data_set "$dataset_for_clevis_unlock")"
          if [[ "$RESEAL" != "" ]]; then
            # We are fine
            echo "$RESEAL"|clevis encrypt tpm2 '{"pcr_ids":"1,4,5,7,9","pcr_bank":"sha256"}' > /tmp/clevis_zfs.jwe
            zdebug "Try to store correct jwe in $dataset_for_clevis_unlock"

            # We need the pool to be writable
            pool=${dataset_for_clevis_unlock%/*}
            ro_state="$(zpool get -H -p -o value readonly "$pool")"
            if [[ "$ro_state" = "on" ]]; then
                zpool export "$pool"
                zpool import -N -o readonly=off -N "$pool"
                zfs set latchset.clevis:jwe="$(cat /tmp/clevis_zfs.jwe)" "$dataset_for_clevis_unlock"
                zpool export "$pool"
                zpool import -N -o readonly=on "$pool"
            else
                zfs set latchset.clevis:jwe="$(cat /tmp/clevis_zfs.jwe)" "$dataset_for_clevis_unlock"
            fi

            # check if we are fine
            jwe_check="$(zfs get -H -p -o value latchset.clevis:jwe -s local $dataset_for_clevis_unlock)"
            if echo "$jwe_check" | clevis decrypt | zfs load-key -n -L prompt "$dataset_for_clevis_unlock"; then
              zdebug "The jwe was correctly stored in dataset $dataset_for_clevis_unlock"
            else
              # We failed. The jwe is not correctly stored in dataset
              zwarn "We failed. The jwe is not correctly stored in dataset $dataset_for_clevis_unlock"
              return 1
            fi
            echo "$RESEAL" >"$KEYFILE"
            return 0
          else
            # We don't want to reseal
            return 1
          fi
        fi
    else
      zwarn "This is strange. Without our help the key is available. Probably keyfile was by mistake put into ZBM initramfs. Plese recheck ZBM configuration"
      return 1
    fi
  else
    #  That's not us
    zdebug "Flag for automatic decryption latchset.clevis:decrypt is not set for dataset $dataset_for_clevis_unlock"
    return 0
  fi
}

######################
### end of clevis hook
######################

######################
### Hook entry point
######################

# Source functional libraries, logging and configuration
sources=(
  /lib/profiling-lib.sh
  /etc/zfsbootmenu.conf
  /lib/zfsbootmenu-kcl.sh
  /lib/zfsbootmenu-core.sh
  /lib/kmsg-log-lib.sh
  /etc/profile
)

for src in "${sources[@]}"; do
  # shellcheck disable=SC1090
  if ! source "${src}" >/dev/null 2>&1 ; then
    echo -e "\033[0;31mWARNING: ${src} was not sourced; unable to proceed\033[0m"
    exec /bin/bash
  fi
done

unset src sources

load_key_clevis "$1"
