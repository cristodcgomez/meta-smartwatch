#!/bin/sh
# dace: forzar el SDP current del USB para que el smblite CARGE.
#
# CAUSA RAIZ (medida 25-09-2026): el smblite arranca con el `usb_icl_votable`
# a ~2 mA (la `SW_ICL_MAX_VOTER`/el driver USB de Android que aqui no corre:
# no hay framework Android). `smblite_lib_configure_usb_icl()` suspende la
# entrada si el ICL <= 25 uA -> POWER_PATH_STATUS=0x29 (USE_USBIN=1 pero
# USBIN_SUSPEND=1 y VALID_INPUT=0) -> `usb/online=0` -> `battery Discharging`,
# el reloj NO carga (aunque el bootloader si carga en el mismo puerto).
#
# El driver USB de Android hace esto mismo via
# POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT; replicamos ese paso: al detectar USB
# presente con online=0, escribimos 500000 uA (SDP_CURRENT_MAX) en
# `usb/input_current_limit` -> `smblite_lib_set_prop_current_max()` vota
# `USB_PSY_VOTER` y quita `SW_ICL_MAX_VOTER` -> online=1 y `battery Charging`
# (medido: current_now pasa a +354 mA).
#
# Solo toca puertos SDP (POWER_SUPPLY_TYPE_USB). DCP/CDP los configura el
# propio PMIC. Idempotente y sin efectos si ya esta online.

US=/sys/class/power_supply/usb
TARGET=500000

[ -e "$US/input_current_limit" ] || exit 0

present=$(cat "$US/present" 2>/dev/null)
online=$(cat "$US/online" 2>/dev/null)
icl=$(cat "$US/input_current_limit" 2>/dev/null)

[ "$present" = "1" ] || exit 0
[ "$online" = "1" ] && exit 0

case "$icl" in ''|*[!0-9]*) exit 0 ;; esac
[ "$icl" -ge "$TARGET" ] && exit 0

echo "$TARGET" > "$US/input_current_limit" 2>/dev/null