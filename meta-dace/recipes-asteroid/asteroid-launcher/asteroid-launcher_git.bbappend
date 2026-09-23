# dace: la corona (RSB) escribe REL_WHEEL y su pulsador emite KEY_MENU.
# El launcher no los consumia: sin WheelHandler la lista de apps no se mueve
# (el estilo por defecto, 000-default-horizontal, no lo trae) y sin
# Keys.onPressed el boton no hace nada. Ver AGENTS.md §6.
#
# IMPORTANTE: el parche esta contra c8c4d4b. La receta base usa SRCREV=AUTOREV,
# asi que lo fijamos aqui: si no, un build que re-fetchee master puede romper
# `git apply` (contexto cambiado).
FILESEXTRAPATHS:prepend:dace := "${THISDIR}/asteroid-launcher:"
SRC_URI:append:dace = " file://0001-dace-crown.patch"
SRCREV:dace = "c8c4d4bd469c8ae5223f4bb7a58e3c96982eb1d9"