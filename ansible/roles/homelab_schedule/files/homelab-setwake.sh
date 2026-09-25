#!/bin/bash
#
# Programs the RTC wakeup for the coming morning, then proves it was armed.
#
# Deployed by the homelab_schedule role. Edit this file, never the copy on the
# host.
#
# Runs at 00:45, fifteen minutes before homelab-shutdown.sh. That timing is why
# the arithmetic reads `today` and not `tomorrow`: at 00:45 the calendar has
# already rolled over, so the machine shutting down at 01:00 is meant to come
# back later the same day. See KE-26 in docs/platform/known-errors.md.
#
# Output reaches the journal under the tag homelab-setwake, because the cron
# line runs this script through systemd-cat. Without that, cron hands stdout to
# the local mailer, which on this host delivers nothing.
#
# Wake times, by the weekday the machine wakes on:
#   Tuesday   (day 2): 16:00
#   Wednesday (day 3): 16:00
#   every other day:   07:30
set -euo pipefail

TODAY=$(date +%u)

case "${TODAY}" in
    2|3)
        WAKE_LABEL="today 16:00"
        ;;
    *)
        WAKE_LABEL="today 07:30"
        ;;
esac

WAKE_TIME=$(date -d "${WAKE_LABEL}" +%s)
NOW=$(date +%s)

# A wake time in the past silently does nothing useful: rtcwake accepts it, the
# alarm never fires, and the machine stays off until somebody presses the button.
# That is the failure this script spent months in, so it is checked rather than
# assumed.
if [ "${WAKE_TIME}" -le "${NOW}" ]; then
    echo "ERROR: computed wake time ${WAKE_LABEL} ($(date -d "@${WAKE_TIME}")) is not in the future" >&2
    exit 1
fi

/usr/sbin/rtcwake -m no -t "${WAKE_TIME}"

# Read the alarm back out of the kernel. rtcwake exiting 0 says the ioctl was
# accepted; this says the hardware holds the alarm. The two came apart for long
# enough that the difference is worth four lines.
ARMED="$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true)"
if [ -z "${ARMED}" ]; then
    echo "ERROR: rtcwake returned 0 but /sys/class/rtc/rtc0/wakealarm is empty - no alarm is armed" >&2
    exit 1
fi

# rtcwake reads the RTC and then the system clock, and subtracts the difference
# from the requested time. When the second ticks between the two reads, the alarm
# lands one second early: measured 07:29:59 for a requested 07:30:00. What this
# check exists to catch is the wrong day or no alarm, so a minute of slack costs
# nothing and an exact comparison fails at random.
OFFSET=$(( ARMED - WAKE_TIME ))
if [ "${OFFSET#-}" -gt 60 ]; then
    echo "ERROR: alarm reads ${ARMED} ($(date -d "@${ARMED}")), expected ${WAKE_TIME} ($(date -d "@${WAKE_TIME}"))" >&2
    exit 1
fi

# One line per night, which persists across the power cycle. It is the only
# evidence this job leaves: the host is down when Prometheus would scrape anything.
echo "wakealarm armed for $(date -d "@${ARMED}") (${WAKE_LABEL})"
