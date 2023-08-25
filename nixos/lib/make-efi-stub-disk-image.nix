/* Technical details

`make-efi-stub-disk-image` has a bit of magic to avoid doing work in a virtual machine.

It relies on the [LKL (Linux Kernel Library) project](https://github.com/lkl/linux) which provides Linux kernel as userspace library.

### Image preparation phase

Image preparation phase will produce the initial image layout in a folder:

- compute the size of the disk image based on the apparent size of the EFI stub kernel image
- create and format a raw, FAT32 ESP filesystem image
- use `cptofs` (LKL tool) to copy the EFI stub kernel bzImage into the ESP filesystem image
- create and partition a raw disk image
- copy the partition image into the corresponding partition in the disk image
- convert the raw disk image into the desired format (qcow2(-compressed), vdi, vpc) using `qemu-img`

### Image Partitioning

#### `none`

No partition table layout is written. The image is a bare filesystem image.

#### `efi`

This partition table type uses GPT and:

- creates an FAT32 ESP partition from 8MiB to specified `bootSize` parameter (256MiB by default), set it bootable

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

, name ? "efi-stub-disk-image"

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

with lib;

let format' = format; in let

  format = if format' == "qcow2-compressed" then "qcow2" else format';

  compress = optionalString (format' == "qcow2-compressed") "-c";

  filename = "efi-stub." + {
    qcow2 = "qcow2";
    vdi   = "vdi";
    vpc   = "vhd";
    raw   = "img";
  }.${format} or format;

  # FIXME: audit which tools are still used
  binPath = with pkgs; makeBinPath (
    [
      util-linux
      parted
      lkl
    ]
    ++ lib.optional deterministic gptfdisk
    ++ stdenv.initialPath);

  # I'm preserving the line below because I'm going to search for it across nixpkgs to consolidate
  # image building logic. The comment right below this now appears in 5 different places in nixpkgs :)
  # !!! should use XML.

  buildImage = ''
    export PATH=${binPath}

    # FIXME: rm?
    # Given lines of numbers, adds them together
    sum_lines() {
      local acc=0
      while read -r number; do
        acc=$((acc+number))
      done
      echo "$acc"
    }

    # FIXME: rm?
    mebibyte=$(( 1024 * 1024 ))

    # FIXME: rm?
    # Approximative percentage of reserved space in an ext4 fs over 512MiB.
    # 0.05208587646484375
    #  × 1000, integer part: 52
    compute_fudge() {
      echo $(( $1 * 52 / 1000 ))
    }

    mkdir $out

    # FIXME: rm?
    root="$PWD/root"
    mkdir -p $root

    # FIXME: rm?
    export HOME=$TMPDIR

    # FIXME: rm?
    chmod 755 "$TMPDIR"

    diskImage=efi-stub.raw

    # FIXME: pass the length into mkfs.vfat instead and use its -C option to create the file
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

      # FIXME: kernal image only
      # Compute required space in filesystem blocks
      diskUsage=$(find . ! -type d -print0 | du --files0-from=- --apparent-size --block-size "${blockSize}" | cut -f1 | sum_lines)
      # Each inode takes space!
      numInodes=$(find . | wc -l)
      # FIXME: same on FAT32?
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

    # Create the ESP
    mkfs.vfat -n ESP $diskImage

    echo "copying staging root to image..."
    # FIXME: set appropriate destination directory
    cptofs -p \
           -t fat32 \
           -i $diskImage \
           $pkgs.kernel / ||
      (echo >&2 "ERROR: cptofs failed. diskSize might be too small for closure."; exit 1)

    ${if partitionTableType != "none" then ''
      # FIXME: operate on a different file than $diskImage
      # FIXME: adjust `mkpart ESP` to start earlier than 8MiB?
      # FIXME: calculate ESP size based on kernel size, `bootSize`, `diskSize`, and/or `additionalSpace`?
      parted --script $diskImage -- \
        mklabel gpt \
        mkpart ESP fat32 8MiB ${bootSize} \
        set 1 boot on
      ${optionalString deterministic ''
          sgdisk \
          --disk-guid=97FD5997-D90B-4AA3-8D16-C1723AEA73C \
          --partition-guid=1:1C06F03B-704E-4657-B9CD-681A087A2FDC \
          $diskImage
      ''}

      # FIXME: use already-calculated values instead of running `partx`?
      # Get start & length of the root partition in sectors to $START and $SECTORS.
      eval $(partx $diskImage -o START,SECTORS --nr ${rootPartition} --pairs)

      # FIXME: copy the ESP filesystem into its partition (possibly using `dd` on $START and $SECTORS?)
    '' else ''
      # FIXME: move filesystem image into final destination
    ''}

    # Move or convert image
    ${if format == "raw" then ''
      mv $diskImage $out/${filename}
    '' else ''
      ${pkgs.qemu-utils}/bin/qemu-img convert -f raw -O ${format} ${compress} $diskImage $out/${filename}
    ''}
    diskImage=$out/${filename}
  '';
in
  pkgs.runCommand name {}
    buildImage
