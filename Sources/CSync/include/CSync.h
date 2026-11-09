#ifndef CSYNC_H
#define CSYNC_H

#include <stdint.h>

/*
 * Atomic loads and stores used by the single-producer / single-consumer audio
 * command queue. Every racing access to the two ring-buffer indices goes
 * through one of these functions, so the ordering the queue documents is the
 * ordering the compiler and the hardware actually provide.
 *
 * Declared static inline so they are inlined into the Swift call site and the
 * package needs no runtime library of its own.
 */

static inline uint64_t csync_load_relaxed(volatile uint64_t *pointer) {
    return __atomic_load_n(pointer, __ATOMIC_RELAXED);
}

static inline uint64_t csync_load_acquire(volatile uint64_t *pointer) {
    return __atomic_load_n(pointer, __ATOMIC_ACQUIRE);
}

static inline void csync_store_relaxed(volatile uint64_t *pointer, uint64_t value) {
    __atomic_store_n(pointer, value, __ATOMIC_RELAXED);
}

static inline void csync_store_release(volatile uint64_t *pointer, uint64_t value) {
    __atomic_store_n(pointer, value, __ATOMIC_RELEASE);
}

#endif /* CSYNC_H */
