#!/bin/bash
# Programs the RTC wakeup for tomorrow based on day of week.
# Run at 00:45 daily (before 01:00 shutdown).
#
# Wake times:
#   Tuesday  (tomorrow = day 2): 16:00
#   Wednesday (tomorrow = day 3): 16:00
#   All other days:               07:30

TOMORROW=$(date -d tomorrow +%u)

case $TOMORROW in
    2|3)
        WAKE_TIME=$(date -d "tomorrow 16:00" +%s)
        ;;
    *)
        WAKE_TIME=$(date -d "tomorrow 07:30" +%s)
        ;;
esac

rtcwake -m no -t "$WAKE_TIME"
