#
# globus.sh - The globus section of config.yaml: the guest collection that
# delivers large results, the client gnoto signs in with, and the app a
# dashboard's reader signs in with to get a run's data.
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
config_setting globus app_client_id text "" "Client ID of the dashboards' Globus app, a public client that returns to <results_base_url>/access.html"
config_setting globus pipelines text "taxprofiler,biobakery" "Pipelines whose zips go to Globus, comma-separated; the rest go to S3"
config_setting globus max_people int 20 "Most Globus identities one run is shared with"
