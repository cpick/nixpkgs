/* Technical details

# FIXME: update these docs

`make-disk-image` has a bit of magic to minimize the amount of work to do in a virtual machine.

It relies on the [LKL (Linux Kernel Library) project](https://github.com/lkl/linux) which provides Linux kernel as userspace library.

The Nix-store only image only need to run LKL tools to produce an image and will never spawn a virtual machine, whereas full images will always require a virtual machine, but also use LKL.

### Image preparation phase

Image preparation phase will produce the initial image layout in a folder:

- devise a root folder based on `$PWD`
- prepare the contents by copying and restoring ACLs in this root folder
- load in the Nix store database all additional paths computed by `pkgs.closureInfo` in a temporary Nix store
- run `nixos-install` in a temporary folder
- transfer from the temporary store the additional paths registered to the installed NixOS
- compute the size of the disk image based on the apparent size of the root folder
- partition the disk image using the corresponding script according to the partition table type
- format the partitions if needed
- use `cptofs` (LKL tool) to copy the root folder inside the disk image

At this step, the disk image already contains the Nix store, it now only needs to be converted to the desired format to be used.

### Image conversion phase

Using `qemu-img`, the disk image is converted from a raw format to the desired format: qcow2(-compressed), vdi, vpc.

### Image Partitioning

#### `none`

No partition table layout is written. The image is a bare filesystem image.

#### `legacy`

The image is partitioned using MBR. There is one primary ext4 partition starting at 1 MiB that fills the rest of the disk image.

This partition layout is unsuitable for UEFI.

#### `legacy+gpt`

This partition table type uses GPT and:

- create a "no filesystem" partition from 1MiB to 2MiB ;
- set `bios_grub` flag on this "no filesystem" partition, which marks it as a [GRUB BIOS partition](https://www.gnu.org/software/parted/manual/html_node/set.html) ;
- create a primary ext4 partition starting at 2MiB and extending to the full disk image ;
- perform optimal alignments checks on each partition

This partition layout is unsuitable for UEFI boot, because it has no ESP (EFI System Partition) partition. It can work with CSM (Compatibility Support Module) which emulates legacy (BIOS) boot for UEFI.

#### `efi`

This partition table type uses GPT and:

- creates an FAT32 ESP partition from 8MiB to specified `bootSize` parameter (256MiB by default), set it bootable ;
- creates an primary ext4 partition starting after the boot partition and extending to the full disk image

#### `hybrid`

This partition table type uses GPT and:

- creates a "no filesystem" partition from 0 to 1MiB, set `bios_grub` flag on it ;
- creates an FAT32 ESP partition from 8MiB to specified `bootSize` parameter (256MiB by default), set it bootable ;
- creates a primary ext4 partition starting after the boot one and extending to the full disk image

This partition could be booted by a BIOS able to understand GPT layouts and recognizing the MBR at the start.

### How to run determinism analysis on results?

Build your derivation with `--check` to rebuild it and verify it is the same.

If it fails, you will be left with two folders with one having `.check`.

You can use `diffoscope` to see the differences between the folders.

However, `diffoscope` is currently not able to diff two QCOW2 filesystems, thus, it is advised to use raw format.

Even if you use raw disks, `diffoscope` cannot diff the partition table and partitions recursively.

To solve this, you can run `fdisk -l $image` and generate `dd if=$image of=$image-p$i.raw skip=$start count=$sectors` for each `(start, sectors)` listed in the `fdisk` output. Now, you will have each partition as a separate file and you can compare them in pairs.
*/
{ pkgs
, lib

, # The size of the disk, in megabytes.
  # if "auto" size is calculated based on the contents copied to it and
  #   additionalSpace is taken into account.
  # FIXME: shift to working on ESP? See bootSize
  diskSize ? "auto"

, # additional disk space to be added to the image if diskSize "auto"
  # is used
  # FIXME: shift to working on ESP? Maybe add additionalBootSpace instead?
  additionalSpace ? "512M"

, # size of the boot partition, is only used if partitionTableType is
  # either "efi" or "hybrid"
  # This will be undersized slightly, as this is actually the offset of
  # the end of the partition. Generally it will be 1MiB smaller.
  # FIXME: rm? See diskSize
  bootSize ? "256M"

, # Type of partition table to use; either "efi" or "none".
  # For "efi" images, the GPT partition table is used and a mandatory ESP
  #   partition of reasonable size is created.
  # For "none", no partition table is created.
  partitionTableType ? "efi"

, # Whether to output have EFIVARS available in $out/efi-vars.fd and use it during disk creation
  touchEFIVars ? false

, # OVMF firmware derivation
  OVMF ? pkgs.OVMF.fd

, # EFI firmware
  efiFirmware ? OVMF.firmware

, # EFI variables
  efiVariables ? OVMF.variables

, # Filesystem label
  # FIXME: rm?
  label ? "nixos"

, # Shell code executed after the VM has finished.
  postVM ? ""

, # Guest memory size
  memSize ? 1024

, name ? "efi-only-disk-image"

, # Disk image format, one of qcow2, qcow2-compressed, vdi, vpc, raw.
  format ? "raw"

  # Whether to fix:
  #   - GPT Disk Unique Identifier (diskGUID)
  #   - GPT Partition Unique Identifier: depends on the layout
  #   - GPT Partition Type Identifier: fixed according to the layout, e.g. ESP partition, etc. through `parted` invocation.
  #   - Filesystem Unique Identifier when fsType = ext4 for *root partition*.
  # BIOS/MBR support is "best effort" at the moment.
  # Boot partitions may not be deterministic.
  # Also, to fix last time checked of the ext4 partition if fsType = ext4.
, deterministic ? true
}:

assert (lib.assertOneOf "partitionTableType" partitionTableType [ "efi" "none" ]);
assert (lib.assertMsg (touchEFIVars -> partitionTableType == "efi") "EFI variables can be used only with a partition table of type: efi.");

with lib;

let format' = format; in let

  format = if format' == "qcow2-compressed" then "qcow2" else format';

  compress = optionalString (format' == "qcow2-compressed") "-c";

  filename = "efi-only." + {
    qcow2 = "qcow2";
    vdi   = "vdi";
    vpc   = "vhd";
    raw   = "img";
  }.${format} or format;

  # FIXME: adjust `mkpart ESP` to start earlier?
  # FIXME: calculate ESP size based on kernel size, `bootSize`, `diskSize`, and/or `additionalSpace`?
  # FIXME: rm `mkpart primary`
  partitionDiskScript = { # switch-case
    efi = ''
      parted --script $diskImage -- \
        mklabel gpt \
        mkpart ESP fat32 8MiB ${bootSize} \
        set 1 boot on \
        mkpart primary ext4 ${bootSize} -1
      ${optionalString deterministic ''
          sgdisk \
          --disk-guid=97FD5997-D90B-4AA3-8D16-C1723AEA73C \
          --partition-guid=1:1C06F03B-704E-4657-B9CD-681A087A2FDC \
          $diskImage
      ''}
    '';
    none = "";
  }.${partitionTableType};

  useEFIBoot = touchEFIVars;

  # FIXME: audit which tools are still used
  binPath = with pkgs; makeBinPath (
    [ rsync
      util-linux
      parted
      e2fsprogs
      lkl
      nix
      systemdMinimal
    ]
    ++ lib.optional deterministic gptfdisk
    ++ stdenv.initialPath);

  # I'm preserving the line below because I'm going to search for it across nixpkgs to consolidate
  # image building logic. The comment right below this now appears in 5 different places in nixpkgs :)
  # !!! should use XML.

  prepareImage = ''
    export PATH=${binPath}

    # Yes, mkfs.ext4 takes different units in different contexts. Fun.
    sectorsToKilobytes() {
      echo $(( ( "$1" * 512 ) / 1024 ))
    }

    sectorsToBytes() {
      echo $(( "$1" * 512  ))
    }

    # Given lines of numbers, adds them together
    sum_lines() {
      local acc=0
      while read -r number; do
        acc=$((acc+number))
      done
      echo "$acc"
    }

    mebibyte=$(( 1024 * 1024 ))

    # Approximative percentage of reserved space in an ext4 fs over 512MiB.
    # 0.05208587646484375
    #  × 1000, integer part: 52
    compute_fudge() {
      echo $(( $1 * 52 / 1000 ))
    }

    mkdir $out

    root="$PWD/root"
    mkdir -p $root

    # FIXME: rm?
    export HOME=$TMPDIR

    # FIXME: rm?
    chmod 755 "$TMPDIR"

    diskImage=efi-only.raw

    ${if diskSize == "auto" then ''
      ${if partitionTableType == "efi" then ''
        # Add the GPT at the end
        gptSpace=$(( 512 * 34 * 1 ))
        # Normally we'd need to account for alignment and things, if bootSize
        # represented the actual size of the boot partition. But it instead
        # represents the offset at which it ends.
        # So we know bootSize is the reserved space in front of the partition.
        reservedSpace=$(( gptSpace + $(numfmt --from=iec '${bootSize}') ))
      '' else ''
        reservedSpace=0
      ''}
      additionalSpace=$(( $(numfmt --from=iec '${additionalSpace}') + reservedSpace ))

      # Compute required space in filesystem blocks
      diskUsage=$(find . ! -type d -print0 | du --files0-from=- --apparent-size --block-size "${blockSize}" | cut -f1 | sum_lines)
      # Each inode takes space!
      numInodes=$(find . | wc -l)
      # Convert to bytes, inodes take two blocks each!
      diskUsage=$(( (diskUsage + 2 * numInodes) * ${blockSize} ))
      # Then increase the required space to account for the reserved blocks.
      fudge=$(compute_fudge $diskUsage)
      requiredFilesystemSpace=$(( diskUsage + fudge ))

      diskSize=$(( requiredFilesystemSpace  + additionalSpace ))

      # Round up to the nearest mebibyte.
      # This ensures whole 512 bytes sector sizes in the disk image
      # and helps towards aligning partitions optimally.
      if (( diskSize % mebibyte )); then
        diskSize=$(( ( diskSize / mebibyte + 1) * mebibyte ))
      fi

      truncate -s "$diskSize" $diskImage

      printf "Automatic disk size...\n"
      printf "  Closure space use: %d bytes\n" $diskUsage
      printf "  fudge: %d bytes\n" $fudge
      printf "  Filesystem size needed: %d bytes\n" $requiredFilesystemSpace
      printf "  Additional space: %d bytes\n" $additionalSpace
      printf "  Disk image size: %d bytes\n" $diskSize
    '' else ''
      truncate -s ${toString diskSize}M $diskImage
    ''}

    ${partitionDiskScript}

    ${if partitionTableType != "none" then ''
      # Get start & length of the root partition in sectors to $START and $SECTORS.
      eval $(partx $diskImage -o START,SECTORS --nr ${rootPartition} --pairs)

      mkfs.${fsType} -b ${blockSize} -F -L ${label} $diskImage -E offset=$(sectorsToBytes $START) $(sectorsToKilobytes $SECTORS)K
    '' else ''
      mkfs.${fsType} -b ${blockSize} -F -L ${label} $diskImage
    ''}

    echo "copying staging root to image..."
    cptofs -p ${optionalString (partitionTableType != "none") "-P ${rootPartition}"} \
           -t ${fsType} \
           -i $diskImage \
           $root/* / ||
      (echo >&2 "ERROR: cptofs failed. diskSize might be too small for closure."; exit 1)
  '';

  moveOrConvertImage = ''
    ${if format == "raw" then ''
      mv $diskImage $out/${filename}
    '' else ''
      ${pkgs.qemu-utils}/bin/qemu-img convert -f raw -O ${format} ${compress} $diskImage $out/${filename}
    ''}
    diskImage=$out/${filename}
  '';

  createEFIVars = ''
    efiVars=$out/efi-vars.fd
    cp ${efiVariables} $efiVars
    chmod 0644 $efiVars
  '';

  buildImage = pkgs.vmTools.runInLinuxVM (
    pkgs.runCommand name {
      preVM = prepareImage + lib.optionalString touchEFIVars createEFIVars;
      buildInputs = with pkgs; [ util-linux e2fsprogs dosfstools ];
      postVM = moveOrConvertImage + postVM;
      QEMU_OPTS =
        concatStringsSep " " (lib.optional useEFIBoot "-drive if=pflash,format=raw,unit=0,readonly=on,file=${efiFirmware}"
        ++ lib.optionals touchEFIVars [
          "-drive if=pflash,format=raw,unit=1,file=$efiVars"
        ]
      );
      inherit memSize;
    } ''
      export PATH=${binPath}:$PATH

      rootDisk=${if partitionTableType != "none" then "/dev/vda${rootPartition}" else "/dev/vda"}

      # It is necessary to set root filesystem unique identifier in advance, otherwise
      # bootloader might get the wrong one and fail to boot.
      # At the end, we reset again because we want deterministic timestamps.
      ${optionalString (fsType == "ext4" && deterministic) ''
        tune2fs -T now ${optionalString deterministic "-U ${rootFSUID}"} -c 0 -i 0 $rootDisk
      ''}
      # make systemd-boot find ESP without udev
      mkdir /dev/block
      ln -s /dev/vda1 /dev/block/254:1

      mountPoint=/mnt
      mkdir $mountPoint
      mount $rootDisk $mountPoint

      # Create the ESP and mount it. Unlike e2fsprogs, mkfs.vfat doesn't support an
      # '-E offset=X' option, so we can't do this outside the VM.
      ${optionalString (partitionTableType == "efi") ''
        mkdir -p /mnt/boot
        mkfs.vfat -n ESP /dev/vda1
        mount /dev/vda1 /mnt/boot

        ${optionalString touchEFIVars "mount -t efivarfs efivarfs /sys/firmware/efi/efivars"}
      ''}

      umount -R /mnt

      # Make sure resize2fs works. Note that resize2fs has stricter criteria for resizing than a normal
      # mount, so the `-c 0` and `-i 0` don't affect it. Setting it to `now` doesn't produce deterministic
      # output, of course, but we can fix that when/if we start making images deterministic.
      # In deterministic mode, this is fixed to 1970-01-01 (UNIX timestamp 0).
      # This two-step approach is necessary otherwise `tune2fs` will want a fresher filesystem to perform
      # some changes.
      ${optionalString (fsType == "ext4") ''
        tune2fs -T now ${optionalString deterministic "-U ${rootFSUID}"} -c 0 -i 0 $rootDisk
        ${optionalString deterministic "tune2fs -f -T 19700101 $rootDisk"}
      ''}
    ''
  );
in
  buildImage
