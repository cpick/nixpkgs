/* Technical details

### Image preparation phase

Image preparation phase will produce the initial image layout in a folder:

- Compute the size of the disk image based on the size of the EFI stub kernel image.
- Create and, optionally, partition a raw disk image.
- Format the FAT32 ESP partition.
- Use `mcopy` to copy the EFI stub kernel bzImage into the ESP filesystem.
- Optionally convert the raw disk image into the desired format (qcow2(-compressed), vdi, vpc) using `qemu-img`.

### Image Partitioning

#### `none`

No partition table layout is written. The image is a bare, FAT filesystem image.

#### `efi`

This partition table type uses GPT and creates a bootable, FAT ESP partition.

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

, # The NixOS configuration from which to fetch the kernal to be installed onto the disk image.
  config

, # Type of partition table to use; either "efi" or "none".
  # For "efi" images, the GPT partition table is used and a FAT ESP partition is created.
  # For "none", no partition table is created, just a bare, FAT filesystem.
  partitionTableType ? "efi"

, name ? "efi-stub-disk-image"

, # Disk image format, one of "qcow2", "qcow2-compressed", "vdi", "vpc", or "raw".
  format ? "raw"

  # Whether to fix:
  #   - GPT Disk Unique Identifier (diskGUID).
  #   - GPT Partition Unique Identifier.
  #   - FAT Serial Number.
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

  binPath = with pkgs; makeBinPath (
    [
      mtools
      parted
    ]
    ++ lib.optional deterministic gptfdisk
    ++ stdenv.initialPath);

  # I'm preserving the line below because I'm going to search for it across nixpkgs to consolidate
  # image building logic. The comment right below this now appears in 5 different places in nixpkgs :)
  # !!! should use XML.

  buildImage = ''
    export PATH=${binPath}

    ${if partitionTableType == "efi" then ''
      # https://en.wikipedia.org/wiki/GUID_Partition_Table
      gptSectors=$(( 1 + 32 )) # partition table header + partition entries
      offsetSectors=$(( 1 + gptSectors )) # protective MBR + primary GPT
      trailingSectors=$gptSectors # secondary GPT
      unset gptSectors
    '' else ''
      offsetSectors=0
      trailingSectors=0
    ''}

    sectorBytes=512

    kernel=${config.boot.kernelPackages.kernel}/bzImage
    kernelSectors=$(du --apparent-size --block-size $sectorBytes $kernel | cut -f1)

    # https://en.wikipedia.org/wiki/Design_of_the_FAT_file_system

    # FAT12/16 usually has 1 reserved sector and a max of 512 32-byte root directory entries.
    # FAT32 usually has 32 reserved sectors and no root directory region.
    maxReservedAndRootDirectoryRegionSectors=33

    # FAT12/16 1 directory entry for '/EFI/BOOT' ('/EFI' is in the root directory region).
    # FAT32 2 directory entries for '/EFI' and '/EFI/BOOT'.
    maxDirectoryEntryClusters=2

    maxClusterSectors=64 # 32KiB clusters with 512B sectors
    minKernelMaxClusters=$(( (kernelSectors + (maxClusterSectors - 1)) / maxClusterSectors ))

    maxDataRegionSectors=$(( (maxDirectoryEntryClusters + minKernelMaxClusters) * maxClusterSectors ))
    unset maxKernelClusters
    unset maxClusterSectors

    # FAT12 3 sectors per 1024 clusters
    # FAT16 1 sector per 256 clusters
    # FAT32 1 sector per 128 clusters
    minClustersPerFatSector=128

    # 2 FATs each addressing maximum number of clusters needed if cluster's size is 1 sector
    maxFatRegionSectors=$(( 2 * ((maxDirectoryEntryClusters + kernelSectors) + (minClustersPerFatSector - 1)) / minClustersPerFatSector ))
    unset minClustersPerFatSector
    unset maxDirectoryEntryClusters
    unset kernelSectors

    maxFatFsSectors=$(( maxReservedAndRootDirectoryRegionSectors + maxFatRegionSectors + maxDataRegionSectors ))
    unset maxFatRegionSectors 
    unset maxDataRegionSectors
    unset maxReservedAndRootDirectoryRegionSectors 

    diskImage=efi-stub.raw
    truncate -s $(( (offsetSectors + maxFatFsSectors + trailingSectors) * sectorBytes )) $diskImage

    offsetBytes=$(( offsetSectors * sectorBytes ))
    unset sectorBytes
    unset trailingSectors
    unset offsetSectors

    ${optionalString (partitionTableType != "none") ''
      # FIXME: optionally round partition boundaries up to 1MiB (or 4 or 8?) and append `align-check optimal 1` command
      # https://lwn.net/Articles/428584/
      parted --script $diskImage -- \
        mklabel gpt \
        mkpart ESP fat32 "$offsetBytes"B 100% \
        set 1 boot on
      ${optionalString deterministic ''
          sgdisk \
          --disk-guid=14F88D31-4BB1-4184-B4BD-E6AD0227533C \
          --partition-guid=1:08F9E924-6CD5-4EF5-BBEF-8FDE08D93C55 \
          $diskImage
      ''}
    ''}

    # Create the ESP filesystem
    mformat -i $diskImage@@$offsetBytes \
      -v ESP \
      -T $maxFatFsSectors \
      -h 64 \
      -s 32 \
      ${optionalString deterministic "-N 989010A2"} \
      ::
    unset maxFatFsSectors

    echo "Copying kernel to image..."
    mmd -i $diskImage@@$offsetBytes ::/EFI ::/EFI/BOOT
    mcopy -i $diskImage@@$offsetBytes $kernel ::/EFI/BOOT/bootx64.efi ||
      (echo >&2 "ERROR: cptofs failed. diskSize might be too small for closure."; exit 1)
    unset kernel
    unset offsetBytes

    # Move or convert image
    mkdir $out
    ${if format == "raw" then ''
      mv $diskImage $out/${filename}
    '' else ''
      qemu-img convert -f raw -O ${format} ${compress} $diskImage $out/${filename}
    ''}
    diskImage=$out/${filename}
  '';
in
  pkgs.runCommand name {}
    buildImage
