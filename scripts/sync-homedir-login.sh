#!/bin/bash
# /etc/profile.d/sync-homedir-login.sh
# Trigger initial sync on user login
if command -v systemctl &>/dev/null && systemctl --user is-enabled sync-homedir.service &>/dev/null; then
    systemctl --user start sync-homedir.service &
fi
