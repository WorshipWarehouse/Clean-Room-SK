#include "CSync.h"

/* The header carries the inline atomic helpers; this translation unit keeps the
 * target a compilable C target and pins the ABI version the Swift side expects. */
int csync_abi_version(void) {
    return 1;
}
