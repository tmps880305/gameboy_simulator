#pragma once

// Minimal C11 atomic helpers for the Swift front end.
// Swift cannot import `_Atomic` types directly and the Synchronization module
// requires iOS 18, so the app stores plain integers and accesses them through
// these inline functions.

#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>

static inline uint32_t gbemu_atomic_load_u32(const uint32_t *p) {
    return atomic_load_explicit((const _Atomic uint32_t *)p, memory_order_acquire);
}

static inline void gbemu_atomic_store_u32(uint32_t *p, uint32_t value) {
    atomic_store_explicit((_Atomic uint32_t *)p, value, memory_order_release);
}

static inline uint32_t gbemu_atomic_exchange_u32(uint32_t *p, uint32_t value) {
    return atomic_exchange_explicit((_Atomic uint32_t *)p, value, memory_order_acq_rel);
}

static inline uint32_t gbemu_atomic_fetch_or_u32(uint32_t *p, uint32_t value) {
    return atomic_fetch_or_explicit((_Atomic uint32_t *)p, value, memory_order_acq_rel);
}

static inline uint32_t gbemu_atomic_fetch_and_u32(uint32_t *p, uint32_t value) {
    return atomic_fetch_and_explicit((_Atomic uint32_t *)p, value, memory_order_acq_rel);
}

static inline int32_t gbemu_atomic_load_i32(const int32_t *p) {
    return atomic_load_explicit((const _Atomic int32_t *)p, memory_order_acquire);
}

static inline void gbemu_atomic_store_i32(int32_t *p, int32_t value) {
    atomic_store_explicit((_Atomic int32_t *)p, value, memory_order_release);
}

static inline uint64_t gbemu_atomic_load_u64(const uint64_t *p) {
    return atomic_load_explicit((const _Atomic uint64_t *)p, memory_order_acquire);
}

static inline void gbemu_atomic_store_u64(uint64_t *p, uint64_t value) {
    atomic_store_explicit((_Atomic uint64_t *)p, value, memory_order_release);
}
