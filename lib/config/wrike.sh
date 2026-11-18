#
# wrike.sh - The wrike section of config.yaml: the bot account that takes job
# requests from Wrike and reports on them there, and the folder its tasks go
# in.
#
# Sourced by:  lib/env.sh
#
# A person sets up Wrike first, as https://cmmr.github.io/gnoto/wrike/ says.
# folder names the folder they made for gnoto, by its name or its Wrike link,
# and gnoto config wrike finds the space, workflow and request form from it,
# suggesting the newest folder the bot can see. webhook_secret, which signs the
# webhook's deliveries to the SQS stack's Lambda, has no question: gnoto config
# sqs and config wrike make a random one in generated.yaml when they first
# need it. A site whose own Lambda already has one sets it here instead, which
# wins.

config_section wrike "Take job requests from a Wrike form, and report each job's progress there"
config_setting wrike enabled bool false ""
config_setting wrike api_token secret "" "The bot account's API token"
config_setting wrike webhook_secret secret "" ""
config_setting wrike poll_minutes int 5 "Minutes between scans of Wrike for changes, with or without SQS, or 0 for none"
config_setting wrike api_url text "https://www.wrike.com/api/v4" "Wrike's API address for this account, https://app-eu.wrike.com/api/v4 for an EU account"
config_setting wrike folder text "" "The folder gnoto's tasks go in, which its request form saves to, by its name or its Wrike link"
