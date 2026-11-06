#
# apptainer.sh - The apptainer section of config.yaml: where Apptainer is, and
# what containers see. It's gnoto's only container engine, so it's on even when
# config.yaml doesn't have it, and can't be turned off.
#
# Sourced by:  lib/env.sh

config_section apptainer "Where Apptainer is, and the paths containers must see"
config_setting apptainer enabled bool true ""
config_setting apptainer bin_dir path "" "Directory holding apptainer, or none to use PATH"
config_setting apptainer binds paths "" "Other paths containers must see, comma-separated, or none"

# Suggests where the launcher found apptainer
config_apptainer_suggest() {
    case $1 in
        bin_dir) printf '%s' "${APPTAINER_BIN_DIR:-${GNOTO_FOUND_APPTAINER_BIN_DIR-}}" ;;
        *) return 1 ;;
    esac
}
