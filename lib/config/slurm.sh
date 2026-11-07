#
# slurm.sh - The slurm section of config.yaml. When it's on, jobs go to Slurm;
# otherwise they run on the machine gnoto starts on.
#
# Sourced by:  lib/env.sh

config_section slurm "Run jobs on a Slurm cluster, rather than on this machine"
config_setting slurm enabled bool false ""
config_setting slurm bin_dir path "" "Directory holding sbatch and Slurm's other commands, or none to use PATH"
config_setting slurm conf path "" "slurm.conf for Slurm to use, or none for its own"
config_setting slurm partition text "" "Partition for gnoto's jobs, or none for Slurm's default"
config_setting slurm account text "" "Account to charge, or none"
config_setting slurm max_cpus int "" "Most CPUs for one task, which caps every request"
config_setting slurm max_memory text "" "Most memory for one task, such as 900.GB"
config_setting slurm max_time text "" "Longest time for one task, such as 24.h"
config_setting slurm job_time text "" "Longest time for a whole run, such as 2-00:00:00 or 48.h, or none for the partition's limit"

# Slurm time, such as 7-00:00:00, 2:00:00 or UNLIMITED, as whole hours, or nothing
slurm_hours() {
    awk -v t="$1" 'BEGIN {
        if (t !~ /^[0-9]/) exit
        days = 0
        if (index(t, "-")) { days = substr(t, 1, index(t, "-") - 1); t = substr(t, index(t, "-") + 1) }
        n = split(t, f, ":")
        hours = (n == 3) ? f[1] : (n == 2 ? f[1] / 60 : 0)
        printf "%d", days * 24 + hours
    }'
}

# The partition chosen so far, or Slurm's default
slurm_partition() {
    local partition=${CONFIG_NEW[partition]-$SLURM_PARTITION}
    [[ -n $partition ]] || partition=$(sinfo -h -o '%P' 2> /dev/null | sed -n 's/\*$//p' | head -1)
    printf '%s' "$partition"
}

# Suggests the current value, or what the launcher and sinfo found: the
# partition's largest node and its time limit
config_slurm_suggest() {
    local value
    case $1 in
        bin_dir) printf '%s' "${SLURM_BIN_DIR:-${GNOTO_FOUND_SLURM_BIN_DIR-}}" ;;
        conf) printf '%s' "${SLURM_CONF:-${GNOTO_FOUND_SLURM_CONF-}}" ;;
        partition)
            sinfo -h -o '%P' > /dev/null 2>&1 ||
                echo "sinfo didn't answer, so nothing is suggested from Slurm." >&2
            slurm_partition
            ;;
        max_cpus)
            value=$(sinfo -h -N -p "$(slurm_partition)" -o '%c' 2> /dev/null | sort -n | tail -1)
            printf '%s' "${SLURM_MAX_CPUS:-$value}"
            ;;
        max_memory)
            value=$(sinfo -h -N -p "$(slurm_partition)" -o '%m' 2> /dev/null | sort -n | tail -1)
            printf '%s' "${SLURM_MAX_MEMORY:-${value:+$(( value / 1024 )).GB}}"
            ;;
        max_time)
            value=$(slurm_hours "$(sinfo -h -p "$(slurm_partition)" -o '%l' 2> /dev/null | head -1)")
            printf '%s' "${SLURM_MAX_TIME:-${value:+$value.h}}"
            ;;
        *) return 1 ;;
    esac
}
