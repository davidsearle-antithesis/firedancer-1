# solfiredancer — Antithesis build extra
#
# Enables Antithesis SDK assertions and fault injection hooks throughout
# the Firedancer codebase.  Link against the Antithesis SDK shared library
# at runtime.
#
# Usage:
#   make -j EXTRAS="debug,antithesis"
#
# To install into the build system:
#   cp antithesis/solfiredancer/config/solfiredancer-with-antithesis.mk config/extra/with-antithesis.mk

FD_HAS_ANTITHESIS:=1
CPPFLAGS+=-DFD_ANTITHESIS_ENABLED=1
CPPFLAGS+=-I$(BASEDIR)/antithesis/solfiredancer/instrumentation
