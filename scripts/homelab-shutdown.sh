#!/bin/bash
# Scheduled shutdown. SnapRAID sync runs at 23:00 daily; shutdown at 01:00 — 2h buffer is sufficient.
/usr/sbin/shutdown -h now
