# dace: la receta original de meta-asteroid solo declara
#     DEPENDS += "mce libmce-glib"
# y el do_compile falla con:
#     plugin-config.h:32:11: fatal error: glib.h: No such file or directory
# porque glib-2.0 no esta en su sysroot (llegaba solo como dependencia de
# libmce-glib, que no basta para los headers). Ademas, al ser el "plugin
# libhybris" de mce, necesita las cabeceras de libhybris (el plugin habla con
# el HAL de Android a traves de ella).
DEPENDS += "glib-2.0 libhybris"
