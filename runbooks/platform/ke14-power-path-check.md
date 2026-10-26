# Runbook: KE-14 power-path check

- **Use when:** [KE-14](../../docs/platform/known-errors.md#ke-14) errors persist on the new boot
  SSD after the [replacement](boot-ssd-replacement.md)
  ([remediation plan](../../docs/platform/remediation-plan.md#power-path-and-ups)).
- **Duration:** 1-2 hours with physical presence, then five boots of observation.
- **Risk:** working in an open case with power applied (step 3); the host may not come back after
  reseating.
- **Last exercised:** never

KE-14: bursts of failed read commands (`DID_SOFT_ERROR`, `DID_TIME_OUT`) against the boot SSD at
SCSI address `9:0:0:0` behind the LSI SAS2008 HBA, at boot and under load. Media and HBA firmware
are excluded. Candidates: 12 V rail sag and HBA heat. Identify the disk by `9:0:0:0` or `by-id`,
never by kernel letter.

## Preconditions

- Physical access, a multimeter, a torch.
- The host down in the nightly off-window; no forced shutdown during the day.
- All guests stopped: `qm list` and `pct list` show nothing `running` before power is pulled.
- Mains disconnected before anything in the case is touched; only step 3 runs with power applied,
  hands clear of the fans.
- Somebody else nearby knows the machine is open.

## Steps

1. Record the state before the shutdown window.
   ```bash
   journalctl -k --since "-7d" | grep -iE 'DID_(SOFT_ERROR|TIME_OUT)|I/O error|reset' | tail -40
   for b in 0 -1 -2 -3 -4; do
     echo "boot $b: $(journalctl -k -b $b | grep -E '9:0:0:0: .*FAILED Result' \
       | grep -oE 'hostbyte=DID_[A-Z_]+' | sort | uniq -c | tr '\n' ' ')"
   done
   smartctl -a /dev/disk/by-id/<boot-ssd-by-id> | head -40
   uptime -s
   ```
   Check: output saved; it is the "before" of the comparison.
2. Power off, mains out. Reseat both ends of the SAS cable, the SSD's SATA power connector and the
   HBA in its slot. Follow the SSD's power lead to the PSU: shared rail, splitter or adapter in the
   path (a splitter is a candidate cause). Note the HBA slot and the dust on the HBA heatsink and
   intake, including "clean".
   Check: every item noted in writing.
3. Power on, case open, disks spinning. Measure 12 V and 5 V at a free connector on the SSD's rail,
   idle and under read load from another terminal:
   ```bash
   # read only
   dd if=/dev/disk/by-id/<boot-ssd-by-id> of=/dev/null bs=1M count=8192 iflag=direct
   ```
   Check: both readings recorded against the ATX tolerance of 11.40-12.60 V (12 V +/- 5 %).
4. Record the PSU: make, model, wattage, manufacture date if labelled (the A.7.11 gap in
   [`physical-controls.md`](../../docs/platform/physical-controls.md)).
   Check: all four values noted, or "not labelled".
5. After a few minutes under load, read temperatures.
   ```bash
   smartctl -a /dev/disk/by-id/<boot-ssd-by-id> | grep -i temperature
   sensors 2>/dev/null | head -30
   ```
   Check: values recorded; if `sensors` reports no HBA reading, record that.

## Verification

Written into [KE-14](../../docs/platform/known-errors.md#ke-14):

1. 12 V at idle and under load, with the tolerance band.
2. PSU make, model, wattage, age.
3. What was reseated; whether a splitter or adapter is in the SSD's power path.
4. Failed commands per boot, read after five boots (the fault skips boots):
   ```bash
   journalctl -k -b 0 | grep -E '9:0:0:0: .*FAILED Result' \
     | grep -oE 'hostbyte=DID_[A-Z_]+' | sort | uniq -c
   ```

## Failure modes

| Result | Meaning | Action |
|---|---|---|
| 12 V out of tolerance under load | Power hypothesis confirmed | PSU replacement in the next hardware window; record it in KE-14 |
| 12 V in tolerance at idle and under load | Power weakened, not excluded (a handheld meter misses transients) | Move the SSD to an onboard SATA port: errors stop -> HBA path; persist -> neither |
| Host does not come back | Reseating or slot problem | [hard-shutdown-recovery.md](hard-shutdown-recovery.md); the host has no console without [host-console-gpu-swap.md](host-console-gpu-swap.md) |

## Rollback

No configuration changes. If the host behaves worse afterwards, put the HBA back in the noted slot
and reseat the moved cable. If a component was swapped, put the original back before drawing a
conclusion, so the result can be attributed to one change.

## Background

The SSD carries every guest root disk, so an `EIO` reaching the thin pool during a guest start can
corrupt a guest filesystem. The `sensors` board reading of `+12V 10.03 V` is unverified, which is
why a meter reading is required. Related: [KE-13](../../docs/platform/known-errors.md#ke-13) (the
other failing disk, a separate fault).
