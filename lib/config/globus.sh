#
# globus.sh - The globus section of config.yaml: the guest collection that
# delivers large results, and the client gnoto signs in with.
#
# Sourced by:  lib/env.sh

config_section globus "Deliver results through a Globus guest collection"
config_setting globus enabled bool false ""
config_setting globus dir path "" "Directory the guest collection shares"
config_setting globus uuid text "" "The guest collection's UUID"
config_setting globus url text "" "The guest collection's web address"
config_setting globus run_prefix text "" "Prefix for runs in the collection, or none for gnoto"
config_setting globus cli_client_id secret "" "Client ID of gnoto's Globus client"
config_setting globus cli_client_secret secret "" "Its client secret"
config_setting globus min_zip_mb int 100 "Zips larger than this many MB go to Globus, and smaller ones to S3 beside the dashboard, when both are set"
