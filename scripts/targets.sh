# Shared target names for provision.sh / build.sh / flash.sh / packaging.
# Public CLI matches ark_jetson_kernel (JAJ | PAB | PAB_V3). Yocto MACHINE stays ark-*.

ark_target() {
    case "$1" in
        JAJ|jaj|ark-jaj) echo JAJ ;;
        PAB|pab|ark-pab) echo PAB ;;
        PAB_V3|pab-v3|ark-pab-v3) echo PAB_V3 ;;
        CAN_PAB|can-pab|ark-can-pab) echo CAN_PAB ;;
        *) return 1 ;;
    esac
}

ark_yocto_machine() {
    case "$1" in
        JAJ) echo ark-jaj ;;
        PAB) echo ark-pab ;;
        PAB_V3) echo ark-pab-v3 ;;
        CAN_PAB) echo ark-can-pab ;;
        *) return 1 ;;
    esac
}

ark_product_slug() {
    case "$1" in
        JAJ) echo jaj ;;
        PAB) echo pab ;;
        PAB_V3) echo pab-v3 ;;
        CAN_PAB) echo can-pab ;;
        *) return 1 ;;
    esac
}

ark_package_name() {
    echo "ark-modalix-$(ark_product_slug "$1").tar.gz"
}
