#!/usr/bin/perl
# Enciende / cicla la alimentacion del chip de BT via /dev/btpower
# (BT_CMD_PWR_CTRL = 0xbfad; el argumento es el modo: 0=off, 1=on, 2=retention).
#
# POR QUE HACE FALTA: aurora (Pixel Watch 2) hace el power-up del chip via
# /dev/btpower. En nuestro reloj el HAL de Qualcomm, con soc=slate, NO vota
# reguladores ("FOR SLATE not voting any Regulators") y sin los supplies en el
# DT `btpower` tampoco sabe que rieles tocar: medido 20-09-2026, pm5100_l13
# (core 1.304V) y pm5100_l17 (IO 1.8V) se quedan en state=disabled y el chip
# esta MUDO (el HAL abre ttyHS0 a 2400 bps y muere con InitTimeOut + err 0x55).
#
#   perl dace-bt-power.pl 1       -> encender
#   perl dace-bt-power.pl 0       -> apagar (corta los rieles)
#   perl dace-bt-power.pl cycle   -> 0 -> 1: apagar y encender, que ademas
#                                    RESETEA el chip (vuelve a arrancar a 2400 bps)
use strict; use warnings;
my $BT_CMD_PWR_CTRL = 0xbfad;
my $mode = shift // 1;
sysopen(my $fh, "/dev/btpower", 2) or die "open /dev/btpower: $!\n";
if ($mode eq "cycle") {
    ioctl($fh, $BT_CMD_PWR_CTRL, 0);
    select(undef, undef, undef, 0.5);
    ioctl($fh, $BT_CMD_PWR_CTRL, 1);
    print "ciclo de power del chip BT (0 -> 1)\n";
} else {
    ioctl($fh, $BT_CMD_PWR_CTRL, $mode) or die "ioctl: $!\n";
    print "BT_CMD_PWR_CTRL pwr=$mode\n";
}
close($fh);
