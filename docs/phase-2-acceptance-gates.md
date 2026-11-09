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

### G2 user-facing desktop quality checks

A running `nova-shell` process is **not** enough. For the installed NOVA image, inspect a settled, rendered GUI (not the KDE splash) and prove the following before calling the Phase 2 **desktop readiness** portion complete:

- **Visual:** save original framebuffer captures after login at 1280×800 and 1920×1080 where supported; reviewer confirms the actual NOVA window content, legible text, unclipped layout, appropriate contrast, and no spinner/splash. Automated non-black-pixel coverage is only a **pre-filter**, not visual certification.
- **Interaction:** check keyboard focus/tab/Enter/Escape, mouse pointer and click response, opening/closing/restarting NOVA window and returning to desktop, graceful handling of a missing daemon, and error/empty/loading feedback. For every visible action, log a real result; buttons that only say "planned" must remain explicitly labeled **not implemented**, not accepted as functional.
- **Host integration:** confirm the packaged app connects to the installed local API, shows a truthful online/offline status, retrieves real system info, and survives daemon restart without requiring a dev server. Do not use mock data.
- **Reliability:** cold reboot and login more than once, observe compositor/app logs and CPU/memory growth, verify clean logout, and repeat across independent disposable QEMU runs. Record actual performance measurements; never claim parity with other operating systems without controlled benchmarks.
- **Scope:** completing this Phase 2 installed-desktop gate does **not** certify a full Mac/Windows-class application ecosystem. File manager, application launcher and global search currently contain placeholders in `apps/shell/src/App.tsx`; these must be implemented and tested in the subsequent shell/runtime roadmap before claiming equivalent features. Premium design is an explicit quality goal, not a pass label inferred from a screenshot.

Required report: exact image SHA-256, source commit, test run, VM firmware, actual screenshot artifact paths, reviewer observations, startup time if measured, interaction results and outstanding limitations. If any subtest is unperformed, mark it **pending** rather than **pass**.

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

- 2026-11-09: Integrated installed-VM #49 ([run 42577790207](https://github.com/anshdeepofficial1/NOVA/actions/runs/42577790207), tested commit **30bc8466a75809d8c218c4ca24e8ff5293e8ef3e**) **PASSED workflow**; downloaded and independently inspected diagnostic ZIP **artifact 13656364888**, 21 files. UEFI and BIOS ext4 installed disk-only results `PASS`, UEFI Btrfs @rootfs/snapshot restoration and non-target disk SHA preservation `PASS`, clean shutdown `verified`. Graphical UEFI result `PASS`; serial contains `NOVA_PHASE2_GUI_SESSION_TYPE=wayland`, `NOVA_PHASE2_USER_DAEMON_HEALTH_OK`, `NOVA_PHASE2_GRAPHICAL_SESSION_OK`, `NOVA_PHASE2_GUEST_PASS`; actual 1280×800 P6 screenshot visually shows NOVA Desktop with **Host connected**, **Local service online**, and real system information. **G2 premium visual/functional acceptance remains OPEN** because KDE Welcome Center and Discover update popup visibly obscure the NOVA workspace; screenshot is not a clean settled desktop and keyboard/mouse interactions, restart/recovery and 1920×1080 capture are not independently verified. Source CI #261/#262 passed on same SHA. This ledger-only evidence commit does not change the tested production ISO. Next fix should suppress the welcome/update overlays in the shipping image and prove a fresh ISO+installed VM visual/interaction test, not merely alter screenshot timing. No physical hardware proof claimed.

- 2026-11-09: Run #48 [42571379942](https://github.com/anshdeepofficial1/NOVA/actions/runs/42571379942), SHA 1c6fc91a41 **FAILED G2**, diagnostic ZIP artifact 13654867817 (20 files) inspected, graphical/uefi-result stage=boot_timeout; kernel boot and production firstboot/temporary daemon health passed, with GUI_POLL attempt=1, GUI_POLL_COMPLETE attempt=1 ready=0 then no more diagnostic markers over the 1,200s host wait. No user-session API marker or screenshot, so the new daemon test was **not reached**; do not blame the daemon yet. Non-graphical UEFI+BIOS and UEFI Btrfs/scratch restore/secondary disk SHA test passed. Fix candidate below defers DBus loginctl until both real Wayland compositor and nova-shell processes exist, consolidates session property reads, adds 15s poll health, and caps graphical host wait at 720s. These are CI-only probe changes; **no runtime fix or G2 pass is claimed** until new exact-head run and screenshot ZIP are independently inspected.

- 2026-11-09: Integrated installed-VM #47 ([run 42567859470](https://github.com/anshdeepofficial1/NOVA/actions/runs/42567859470), commit c18b6b55da) **succeeded as an automated QEMU workflow**; diagnostic artifact 13652931374 inspected (21 files). Both UEFI and BIOS installed ext4 disk-only boots report firstboot/daemon/guest pass and shutdown=verified. UEFI Btrfs probe reports @rootfs, BTRFS_LAYOUT_OK, SNAPSHOT_RESTORE_DATA_OK, secondary disk SHA preserved and shutdown=verified. Graphical serial reports GUI_POLL_COMPLETE attempt=1 ready=0, then session ID=1, active Wayland, GRAPHICAL_SESSION_OK, GUEST_PASS; 1280x800 P6 screenshot shows the *real NOVA Desktop window*. **Visual acceptance still BLOCKED**: KDE Welcome Center obscures the NOVA window and the NOVA UI visibly reports "Local service offline", despite the earlier temporary root-level daemon health marker. Desktop controls include intentionally unimplemented placeholders. This is a concrete user-facing gap; a green CI workflow is not full G2 signoff. Next targeted probe requires the installed novatest systemd user daemon and actual Tauri-origin API to respond, with bounded wait and failure diagnostics. No production image fix or hardware proof claimed.


- 2026-11-09: Run #46 42558405522 on b39b99665f **FAILED G2** after UEFI installation, production firstboot and daemon health: artifact 13650577112 (20 files) contains `nova-installed-graphical/uefi-result.txt` with `stage=boot_timeout`; serial stops after `NOVA_PHASE2_GUI_POLL attempt=1`, without `GRAPHICAL_SESSION_OK`, `GUEST_PASS` or graphical PPM. Btrfs layout/snapshot test and non-target preservation step passed separately; source CI #249/#250 passed. Do not infer whether the guest hung inside loginctl or became CPU-starved; the old log does not distinguish them. Commit c18b6b55 adds an after-probe heartbeat to narrow the next failure. No G2 certification.

- 2026-11-09: New sequential gate ledger added on PR #13 branch. No gate newly certified by writing this document.
