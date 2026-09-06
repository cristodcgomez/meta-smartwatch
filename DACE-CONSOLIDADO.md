# DACE BRING-UP — CONSOLIDATED STATE (session 06-09-2026)

Codename: `dace` = TicWatch Pro 5 (monaco/SW5100). Kernel aurora (google-eos
5.15.144), DT T5 (monaco-real + monacop), GKI scheme.

## Verdict
- Kernel dace boots to userspace. ✅
- Base STABLE (charger chain commented) = kernel alive, init loop P20/P26.
- USB/adb is BLOCKED by a NON-DETERMINISTIC kernel panic when the charger
  (qpnp-smblite) chain is loaded. Real panic message never captured (no UART,
  post-panic goes straight to fastboot — edl unusable).

## Base stable (hybrid27) — what to keep
- modules.load.dace: charger/BMS chain COMMENTED OUT (qpnp-smblite,
  qti-qbg, google-bms/battery/charger, sw5100_bms).
- Watchdogs off in sw5100.fragment (WATCHDOG_CORE, HANDLE_BOOT, WQ_WATCHDOG,
  QCOM_SOC_WATCHDOG).
- qnoc-monaco commented in modules.load.dace.
- init has on-screen telemetry (boot-color + P-text, /sys/kernel/dace_text).

## VIA 1 (next session)
1. Add dwc3-msm-probe-trace.patch (from ticwatch, google-eos compatible) to the
   dace kernel SRC_URI → /sys/kernel/dace_glue exposes glue C/P/G/D.
2. Print C/P/G/D on dace_text.
3. Reintroduce qpnp-smblite ONLY, flash → read the panic / C/P/G/D.
4. Directed fix; if telemetry does not answer, STOP and re-analyze.
5. Once charger is deterministic → gadget adb + adbd → UDC → adb (18d1:d002).

## Verify commands
- On-screen: P26 poll / DFR / DRV, P20 ADB alive.
- Host: lsusb (expect 18d1:d002 adb, or 05c6:900e EDL, or 18d1:d00d fastboot).

## Restoration
- ota-stock/blobs → boot/vendor/init/vbmeta/vbmeta_system/dtbo (stock).
- vbmeta flags=3.