#
# core.sh - The core section of config.yaml: where gnoto keeps its data, and how
# long. It's always on, so it has no enabled.
#
# Sourced by:  lib/env.sh

config_section core "Where gnoto keeps its runs, caches and databases, and for how long"
config_setting core data_dir dir "" "Data directory, for runs, caches and logs, on storage every compute node sees"
config_setting core db_dir dir "" "Database directory, which can be large"
config_setting core input_roots paths "" "Paths form requests may read FASTQs under, comma-separated, or none"
config_setting core nextflow_config path "" "Extra Nextflow config for this site, or none"
config_setting core expiration_notice_days int 14 "Days of warning before results expire, which is also the fewest they're kept"
config_setting core keep_run_days int 14 "Days a failed run's logs, or a --debug run's directory, are kept"

# The database directory follows the data directory unless it was set apart
config_core_suggest() {
    case $1 in
        db_dir)
            if [[ $DB_DIR == "$DATA_DIR/db" ]]; then
                printf '%s' "${CONFIG_NEW[data_dir]:-$DATA_DIR}/db"
            else
                printf '%s' "$DB_DIR"
            fi
            ;;
        *) return 1 ;;
    esac
}
