# Runbook: KE-14 power-path verification

## Problem

[KE-14](../../docs/platform/known-errors.md#ke-14) is a recurring burst of `DID_SOFT_ERROR` against
the boot SSD, confined to the boot window. The media has been excluded, so has the HBA firmware.
The leading hypothesis is a sagging 12 V rail, and it has been the leading hypothesis for months
because verifying it needs somebody in front of the machine rather than in front of a terminal.

That disk carries every VM and LXC root disk. An `EIO` reaching the thin pool while a guest starts
can corrupt a guest filesystem, so this is not a cosmetic log entry.

This runbook is the check. It is written down so the verification becomes a step with a
precondition rather than an intention that keeps being deferred - and so that a negative result is
recorded as a result, which is the outcome most likely to be lost.

**Never identify this disk by its kernel letter.** It was documented as `sdc` for a month and
enumerated as `sda` on 2026-08-13. Use the SCSI address `9:0:0:0` or a `by-id` path.

## Preconditions

- Physical access to the machine, a multimeter, and a torch.
- The host is powered down. The nightly RTC schedule already provides this window; do not force a
  shutdown during the day for it.
- Guests are down with it. Confirm before pulling power, because a `qm stop` is not what should
  end this session: `pct list` and `qm list` both empty of running entries.
- Wall power disconnected before anything inside the case is touched. The 12 V measurement is the
  one step that happens with power applied, and it happens with the case open and hands clear of
  the fans.
- A second person in the flat, or at minimum somebody who knows the machine is open.

## Procedure

### 1. Record the state before touching anything

```bash
# On the host, before the shutdown window:
journalctl -k --since "-7d" | grep -iE 'DID_SOFT_ERROR|I/O error|reset' | tail -40
smartctl -a /dev/disk/by-id/<boot-ssd-by-id> | head -40
uptime -s
```

Save the output. The point of the exercise is a before-and-after, and after is worthless alone.

### 2. Cables and seating, power off

- Reseat both ends of the SAS cable between the HBA and the backplane or drive.
- Reseat the SATA power connector on the boot SSD, and follow that lead back to the PSU: note
  whether it shares a rail with the other drives, and whether a splitter or adapter is in the path.
  A splitter is a candidate cause in its own right.
- Reseat the HBA in its slot. Note the slot.
- Note dust load on the HBA heatsink and on the intake. Write down what you see, including
  "clean" - an unrecorded observation is one that will be made again.

### 3. Twelve volts, power on

With the case open and the machine booted to the point where the disks spin:

- Measure 12 V and 5 V at a free Molex or SATA power connector on the same rail as the boot SSD.
- Record the idle reading, then a reading while the disks are under load. Generate load from
  another terminal:

  ```bash
  # Read, never write. This disk is the one under suspicion.
  dd if=/dev/disk/by-id/<boot-ssd-by-id> of=/dev/null bs=1M count=8192 iflag=direct
  ```

- ATX tolerance on the 12 V rail is plus or minus 5 percent, which is 11.40 V to 12.60 V. A reading
  inside tolerance at idle that drops out of it under load is the finding this whole exercise is
  looking for. A reading inside tolerance in both states is also a finding, and it moves the
  hypothesis rather than confirming it.

### 4. Record the PSU

Make, model, wattage, and the manufacture date if the label carries one. This is the gap
[`physical-controls.md`](../../docs/platform/physical-controls.md) records under A.7.11, and the
measurement above is worth much less without it: a six-year-old unit reading 11.6 V under load
means something different from a new one doing the same.

### 5. HBA temperature

```bash
# After the host is back up and has been under load for a few minutes:
smartctl -a /dev/disk/by-id/<boot-ssd-by-id> | grep -i temperature
sensors 2>/dev/null | head -30
```

An LSI SAS2008 in a case with no directed airflow runs hot enough to throttle or fault, and it is
the component the transport errors are attributed to. If `sensors` reports nothing useful, note
that too - the absence of a reading is why this has never been ruled in or out.

## Verification

The check is complete when all four of these are written into
[KE-14](../../docs/platform/known-errors.md#ke-14):

1. The 12 V reading at idle and under load, with the tolerance band stated.
2. The PSU's make, model, wattage and age.
3. What was reseated, and whether a splitter or adapter sits in the drive's power path.
4. A boot-window journal read from the first boot after the work:

   ```bash
   journalctl -k -b 0 | grep -iE 'DID_SOFT_ERROR|I/O error' | head -20
   ```

One clean boot proves nothing - the fault is intermittent and has skipped boots before. Read the
same command after five boots before calling anything improved, and record the count.

## Failure

- **The reading is out of tolerance under load.** The hypothesis is confirmed and the remedy is a
  PSU, which is a purchase and belongs in the hardware window with the aux-disk replacement. Until
  then, nothing changes about the risk: record it and keep the guest-backup schedule.
- **The reading is in tolerance in both states.** The power hypothesis is weakened, not dead - a
  transient dip is not visible on a handheld meter. The next discriminating step is moving the
  boot SSD off the HBA to an onboard SATA port, which is remediation plan Tier 2 item 6 and needs
  no purchase: if the bursts stop it was the HBA path, if they persist it is neither.
- **The host does not come back.** This is the case the preconditions exist for. The recovery path
  is [`hard-shutdown-recovery.md`](hard-shutdown-recovery.md), and note that the hypervisor has no
  out-of-band console: the GPU is passed through, so a monitor shows nothing until the passthrough
  is removed from vm100's configuration.

## Rollback

Nothing in this procedure changes configuration, so there is no state to roll back. The two
reversible physical acts are the reseating and the slot change; if the host behaves worse
afterwards, put the HBA back in the slot it came from and reseat the cable you moved. That is the
reason step 2 says to note the slot.

If a component was swapped during the session, put the original back before concluding anything.
Two changes at once produce a result that explains neither.

## Related

- [KE-14 - the incident](../../docs/platform/known-errors.md#ke-14)
- [KE-13 - the other failing disk, and why they are not the same fault](../../docs/platform/known-errors.md#ke-13)
- [Physical and environmental controls](../../docs/platform/physical-controls.md)
- [Hard shutdown recovery](hard-shutdown-recovery.md)
