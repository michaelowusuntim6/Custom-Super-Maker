#!/bin/sh
# Copyleft 2021-2025 Uluruman (Modified for EROFS/Universal Support)
version=1.17.0

script_dir=$(dirname $0)
lptools_path="$script_dir/lpunpack_and_lpmake"
heimdall_path="$script_dir/heimdall"
empty_product_path="$script_dir/misc/product.img"
empty_system_ext_path="$script_dir/misc/system_ext.img"
system_required="simg2img tar unxz lz4 unzip gzip jq file"

# Colors
if [ ! $NO_COLOR ] && [ $TERM != "dumb" ]; then
  RED="\033[1;31m"
  GREEN="\033[1;32m"
  CYAN="\033[1;36m"
  YELLOW="\033[1;33m"
  BLUE="\033[1;34m"
  BR="\033[1m"
  NC="\033[0m"
fi

# Ctrl+C trap
trap_func() {
  if [ "$new_super_dir/super.img" != "$new_super" ] && [ -f "$new_super_dir/super.img" ]; then
    echo "Renaming \"super.img\" back to \"$new_super_name\""
    mv "$new_super_dir/super.img" "$new_super"
  fi
  echo "Action aborted. Exiting..."
  exit 1
}

mkdircr() {
  mkdir -p "$1"
  if [ ! $? -eq 0 ]; then
    echo "Cannot create directory. Exiting..."
    exit 1
  fi
}

lpdump() {
  retval=$($lptools_path/lpdump "$stock_super_raw" -j | jq -r '.'$1'[] | select(.name == "'$2'") | .'$3)
}

# Check for the system requirements
for i in $system_required
do
  if [ ! $(which "$i") ]; then
    echo "The \"$i\" tool was not found on your system."
    exit 1
  fi
done

# Parse arguments
optstr="?exsmwpr:v:"
while getopts $optstr opt; do
  case "$opt" in
    e) empty_product=true ;;
    x) empty_system_ext=true ;;
    s) silent_mode=true ;;
    m) manual_super_name=true ;;
    w) writable=true ;;
    p) purge_all=true ;;
    r) rdir="$OPTARG" ;;
    v) custom_vdlkm="$OPTARG" ;;
    \?) exit 1 ;;
  esac
done
shift $(expr $OPTIND - 1)

# Check the root dir
if [ ! "$rdir" ]; then
  rdir="."
fi

# Set work directory
rps_dir="$rdir"/repacksuper
if [ ! -d "$rps_dir" ]; then
  mkdircr "$rps_dir"
fi

# Identify the source
stock_super="$1"
new_system_src="$2"
new_super="$3"

# Convert Stock Super to Raw
echo
printf "${CYAN}Converting stock super to raw...${NC}\n"
stock_super_raw="$rps_dir"/super.raw
if ! file -b -L "$stock_super" | grep "sparse image" > /dev/null; then
    cp "$stock_super" "$stock_super_raw"
else
    simg2img "$stock_super" "$stock_super_raw"
fi

# Unpack
super_dir="$rps_dir"/super
mkdircr "$super_dir"
printf "${CYAN}Unpacking super partitions...${NC}\n"
"$lptools_path"/lpunpack "$stock_super_raw" "$super_dir"

# Replace System
new_system="$super_dir"/system.img
cp "$new_system_src" "$new_system"

# Ensure new system is raw
if file -b -L "$new_system" | grep "sparse image" > /dev/null; then
    mv "$new_system" "$new_system.sparse"
    simg2img "$new_system.sparse" "$new_system"
    rm "$new_system.sparse"
fi

# Get Sizes and Groups
system_size=$(stat --format="%s" "$new_system")
lpdump "block_devices" "super" "size"
block_device_table_size=$retval
lpdump "partitions" "system" "group_name"
system_group=$retval
lpdump "groups" "$system_group" "maximum_size"
groups_max_size=$retval

# --- 32GB MODEL OVERRIDE ---
# If detected size is 0 or extremely large, or if we want to be safe for A04s
if [ "$block_device_table_size" -gt 4294967296 ] || [ "$block_device_table_size" -eq 0 ]; then
    echo "Applying 32GB Model Size Patch (4GB)..."
    block_device_table_size=4294967296
    groups_max_size=4292870144
fi

# Partitions check
if [ $empty_product ]; then product_img="$empty_product_path"; else product_img="$super_dir"/product.img; fi
if [ $empty_system_ext ]; then system_ext_img="$empty_system_ext_path"; else system_ext_img="$super_dir"/system_ext.img; fi
if [ -f "$product_img" ]; then product_size=$(stat --format="%s" "$product_img"); fi
if [ -f "$system_ext_img" ]; then system_ext_size=$(stat --format="%s" "$system_ext_img"); fi
if [ -f "$super_dir"/vendor.img ]; then vendor_size=$(stat --format="%s" "$super_dir"/vendor.img); fi
if [ -f "$super_dir"/odm.img ]; then odm_size=$(stat --format="%s" "$super_dir"/odm.img); fi

# Final Repack
printf "${CYAN}Packing new super.img for Samsung A04s...${NC}\n"
"$lptools_path"/lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
  --device super:$block_device_table_size --group $system_group:$groups_max_size \
  --partition system:readonly:$system_size:$system_group --image system="$new_system" \
  ${vendor_size:+--partition vendor:readonly:$vendor_size:$system_group --image vendor="$super_dir/vendor.img"} \
  ${odm_size:+--partition odm:readonly:$odm_size:$system_group --image odm="$super_dir/odm.img"} \
  ${product_size:+--partition product:readonly:$product_size:$system_group --image product="$product_img"} \
  ${system_ext_size:+--partition system_ext:readonly:$system_ext_size:$system_group --image system_ext="$system_ext_img"} \
  --sparse --output "$new_super"

echo "Done. Repacked image is at $new_super"
