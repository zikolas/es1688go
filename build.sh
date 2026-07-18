#!/bin/sh
# ES1688GO build — NASM flat binaries (byte-identical on-box with NASM at C:\NASM)
set -e
nasm -f bin -o ES1688GO.COM ES1688GO.ASM
nasm -f bin -o probes/SSCALL.COM probes/SSCALL.ASM
nasm -f bin -o probes/CISDUMP.COM probes/CISDUMP.ASM
nasm -f bin -o probes/CSINFO.COM probes/CSINFO.ASM
nasm -f bin -o probes/MPUTEST.COM probes/MPUTEST.ASM
nasm -f bin -o probes/MPUTST2.COM probes/MPUTST2.ASM
ls -la ES1688GO.COM probes/*.COM
