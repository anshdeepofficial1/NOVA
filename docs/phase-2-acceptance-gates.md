# NOVA Phase 2 — Sequential acceptance gates (living ledger)

Owner: NOVA development / GitHub Actions. Scope: **Installer and System Initialization**. Source of truth for scope: [Phase 2 implementation plan](phase-2-implementation-plan.md). Updated: 2026-11-09.

This ledger is **not** a certification. Do not check a gate off merely because a script exists, CI source checks pass, a VM prints a marker, or a PR is mergeable. Preserve exact commit SHA, workflow run URL, result/serial logs and diagnostic ZIP; read the evidence before marking complete. Fix the **first failing gate** before proceeding. No user's device testing. No physical or valuable disk writes, even to collect evidence.

## Gate G0 — Source provenance and disposable-disk isolation

**Acceptance:** exact ISO build from immutable successful `Build NOVA ISO` run on main, SHA-256 checked before installation, QEMU-only fresh qcow2 primary target, non-target writable file-backed disk with before/after SHA-256 equality, strict /dev/vda preseed and no shipping destructive preseed. Verify failure on reused disk and mismatched checksum. Record ISO run+SHA, Actions run+SHA, hashes and reject-test output.

**Existing evidence:** installed VM #41 (run 42472222973) passed on 390ffa1; #42 (42485821022) independently logs `NOVA_PHASE2_NON_TARGET_DISK_PRESERVED` and correct ISO download/check. These are VM-only, not physical-disk safety certification.

## Gate G1 — UEFI/BIOS production-firstboot baseline

**Acceptance:** both firmware installations using the exact immutable ISO, ISO removed, real disk-only boot, partition/bootloader/selected filesystem and swap checked, exact `NOVA_PHASE2_PRODUCTION_FIRSTBOOT_OK` + daemon health + guest-pass markers, validated account, clean shutdown, separate logs. Production firstboot must be installed in the release image; CI-only marker cannot replace it. Repeat after any production installer change.

**Existing evidence:** main run #32 42443502022 and integrated run #41 42472222973; do not extrapolate to encrypted or Btrfs production paths.

## Gate G2 — Graphical login and rendered NOVA desktop (CURRENT ACTIVE GATE)

**Acceptance:** SDDM active, novatest session is active Wayland, real `kwin_wayland` and `nova-shell` processes, final guest-pass marker, normal shutdown, and **visually inspected framebuffer screenshot of settled desktop, not black screen or Plasma splash**. Test multiple independent disposable installs to investigate intermittent failures. Require bounded loginctl/D-Bus probes with explicit failure logs; record guest serial, screenshot dimensions/nonblank statistics and visual review, plus VM result file. A screenshot size check alone is insufficient. Validate session restart, daemon crash recovery, and multi-user separation in dedicated follow-ups.

**Known failure:** #42 42485821022 reaches firstboot and daemon-health but times out before GUI evidence. #41 workflow returned green, but captured screenshot displayed KDE startup splash rather than settled desktop; treat visual acceptance as unproven. Latest candidate b39b99665f (bounded graphical probes and shutdown grace) is under testing in #46 42558405522; do not call passed without actual result and artifact inspection. Keep PR #13 draft until corrected evidence is green.

## Gate G3 — Shipping storage/account/swap policy (not just CI overlay)

**Acceptance:** released interactive installer actually supports a safe selectable target, Btrfs `@rootfs`, persistent `@home` and `@snapshots` after reboot, correct fstab/options, swap behavior (including encrypted installation policy), user/home ownership and recovery partition expectations. Verify ext4 compatibility and UEFI+BIOS variations where supported. Run non-target preservation and no-overwrite tests in isolated images.

**Existing evidence:** CI-only Btrfs layout + scratch snapshot restoration VM #36 42443966562 and integrated #41. Their opt-in scripts do not demonstrate production layout or update rollback. Gate stays open.

## Gate G4 — Optional LUKS encryption and installer error recovery

**Acceptance:** released installer offers opt-in LUKS with safe target confirmation and no silent destructive defaults; encrypted root unlock works after cold reboot; incorrect passphrase/cancellation and installation interruption recover safely without harming non-target disks. No secrets or recovery keys in logs. Verify swap encryption policy, initramfs and bootloader interaction in UEFI/BIOS as appropriate, with diagnostic artifacts. Gate stays open until actual encrypted installed VM passes.

## Gate G5 — Snapshot/update transaction and rollback

**Acceptance:** real production root snapshots before updates, signed package/update provenance checked, failed or interrupted update must recover the bootable known-good root, preserve `@home`, show correct bootloader selection and clear recovery path. Validate unclean interruption by fault injection on disposable disk snapshots and verify data/boot state after reboot. CI scratch-subvolume restoration is not sufficient. Gate stays open.

## Gate G6 — Runtime hardware and operational acceptance

**Acceptance (virtual):** confirm networking, audio, desktop app launch, NOVA daemon as a user service, restart/crash recovery, multiple users, reboots and suspend where QEMU supports faithful testing. Save IDs/logs/screenshots. **Physical qualification:** independent AMD and Intel hosts, NVIDIA/AMD GPU, Wi-Fi/Bluetooth, storage, USB, suspend/battery, audio and multi-display evidence from real lab rigs with hardware IDs, firmware, reproducible steps and signed-off actual results. Never synthesize, infer or mark physical evidence green from QEMU. Physical-lab absence explicitly blocks full Phase 2 release sign-off.

## Gate G7 — Reconciliation, regression, release

**Acceptance:** all previous gates have independent passing evidence against intended release code; reconcile PR #9/#10/#12 with PR #13 without overwriting verified main firstboot, review merge diff for CI-only vs production changes, rerun exact-head source/ISO/installed acceptance, review artifacts/screenshots, then merge safe, reviewed implementation. Test merged main and update signed evidence ledger. Do **not** merge CI-only PR #13 as a substitute for remaining production features.

## Execution protocol

1. Read newest pushed GitHub Actions runs via `GET /repos/anshdeepofficial1/NOVA/actions/runs?branch=work%2Fphase2-integrated-vm-acceptance`, **including push events**; commit-run lookup alone omits them.
2. For first failed/latest exact-head run, inspect job steps and full log plus downloadable `NOVA-Phase2-installation-diagnostics` ZIP; compare result files, serial markers and PPM pixels.
3. Implement the smallest evidence-backed fix on an isolated draft branch. Run syntax/static/unit checks, then trigger **new commit/appropriate workflow**; do not rerun obsolete SHAs as if testing a fix.
4. Require a complete independently inspected pass at this gate; record run, commit, artifact ID and the limitation of the evidence. If pending, retain status pending; do not promote next gate.
5. Only publish meaningful changes/new evidence. If unchanged, continue scheduled checks without repeating stale progress reports. Physical hardware lab evidence cannot be acquired by cloud VM and must remain an explicit blocker.

## Change log

- 2026-11-09: Run #46 42558405522 on b39b99665f **FAILED G2** after UEFI installation, production firstboot and daemon health: artifact 13650577112 (20 files) contains `nova-installed-graphical/uefi-result.txt` with `stage=boot_timeout`; serial stops after `NOVA_PHASE2_GUI_POLL attempt=1`, without `GRAPHICAL_SESSION_OK`, `GUEST_PASS` or graphical PPM. Btrfs layout/snapshot test and non-target preservation step passed separately; source CI #249/#250 passed. Do not infer whether the guest hung inside loginctl or became CPU-starved; the old log does not distinguish them. Commit c18b6b55 adds an after-probe heartbeat to narrow the next failure. No G2 certification.

- 2026-11-09: New sequential gate ledger added on PR #13 branch. No gate newly certified by writing this document.
