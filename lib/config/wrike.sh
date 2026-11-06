#
# wrike.sh - The wrike section of config.yaml: the bot account that takes job
# requests from Wrike and reports on them there.
#
# Sourced by:  lib/env.sh

config_section wrike "Take job requests from a Wrike form, and report each job's progress there"
config_setting wrike enabled bool false ""
config_setting wrike api_token secret "" "The bot account's API token"
config_setting wrike webhook_secret secret "" "A secret you choose, which signs webhook deliveries, used only with SQS"
config_setting wrike poll_minutes int 5 "Minutes between scans of Wrike for changes, with or without SQS, or 0 for none"
