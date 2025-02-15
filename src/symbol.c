// This file is a part of Julia. License is MIT: https://julialang.org/license

/*
  Symbol table
*/

#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "julia.h"
#include "julia_internal.h"
#include "julia_assert.h"

#ifdef __cplusplus
extern "C" {
#endif

uv_mutex_t symtab_lock;
static _Atomic(jl_sym_t*) symtab = NULL;

#define MAX_SYM_LEN ((size_t)INTPTR_MAX - sizeof(jl_taggedvalue_t) - sizeof(jl_sym_t) - 1)

static uintptr_t hash_symbol(const char *str, size_t len) JL_NOTSAFEPOINT
{
    uintptr_t oid = memhash(str, len) ^ ~(uintptr_t)0/3*2;
    // compute the same hash value as v1.6 and earlier, which used `hash_uint(3h - objectid(sym))`
    return inthash(-oid);
}

static size_t symbol_nbytes(size_t len) JL_NOTSAFEPOINT
{
    return ((sizeof(jl_sym_t) + len + 1 + 7) & -8);
}

static jl_sym_t *mk_symbol(const char *str, size_t len) JL_NOTSAFEPOINT
{
    size_t nb = symbol_nbytes(len);
    // jl_sym_t is an object and needs to be allocated with jl_gc_permobj
    // but its type is set below with jl_set_typetagof since
    // jl_symbol_type might not have been initialized
    jl_sym_t *sym = (jl_sym_t*)jl_gc_permobj(nb, NULL, sizeof(void*));
    jl_set_typetagof(sym, jl_symbol_tag, GC_OLD_MARKED);
    jl_atomic_store_relaxed(&sym->left, NULL);
    jl_atomic_store_relaxed(&sym->right, NULL);
    sym->hash = hash_symbol(str, len);
    memcpy(jl_symbol_name(sym), str, len);
    jl_symbol_name(sym)[len] = 0;
    return sym;
}

static jl_sym_t *symtab_lookup(_Atomic(jl_sym_t*) *ptree, const char *str, size_t len, _Atomic(jl_sym_t*) **slot) JL_NOTSAFEPOINT
{
    jl_sym_t *node = jl_atomic_load_relaxed(ptree); // consume
    uintptr_t h = hash_symbol(str, len);

    // Tree nodes sorted by major key of (int(hash)) and minor key of (str).
    while (node != NULL) {
        intptr_t x = (intptr_t)(h - node->hash);
        if (x == 0) {
            x = strncmp(str, jl_symbol_name(node), len);
            if (x == 0 && jl_symbol_name(node)[len] == 0) {
                if (slot != NULL)
                    *slot = ptree;
                return node;
            }
        }
        if (x < 0)
            ptree = &node->left;
        else
            ptree = &node->right;
        node = jl_atomic_load_relaxed(ptree); // consume
    }
    if (slot != NULL)
        *slot = ptree;
    return node;
}

jl_sym_t *_jl_symbol(const char *str, size_t len) JL_NOTSAFEPOINT // (or throw)
{
#ifndef __clang_gcanalyzer__
    // Hide the error throwing from the analyser since there isn't a way to express
    // "safepoint only when throwing error" currently.
    if (len > MAX_SYM_LEN)
        jl_exceptionf(jl_argumenterror_type, "Symbol name too long");
#endif
    assert(!memchr(str, 0, len));
    _Atomic(jl_sym_t*) *slot;
    jl_sym_t *node = symtab_lookup(&symtab, str, len, &slot);
    if (node == NULL) {
        uv_mutex_lock(&symtab_lock);
        // Someone might have updated it, check and look up again
        if (jl_atomic_load_relaxed(slot) != NULL && (node = symtab_lookup(slot, str, len, &slot))) {
            uv_mutex_unlock(&symtab_lock);
            return node;
        }
        node = mk_symbol(str, len);
        jl_atomic_store_release(slot, node);
        uv_mutex_unlock(&symtab_lock);
    }
    return node;
}

JL_DLLEXPORT jl_sym_t *jl_symbol(const char *str) JL_NOTSAFEPOINT // (or throw)
{
    return _jl_symbol(str, strlen(str));
}

JL_DLLEXPORT jl_sym_t *jl_symbol_lookup(const char *str) JL_NOTSAFEPOINT
{
    return symtab_lookup(&symtab, str, strlen(str), NULL);
}

JL_DLLEXPORT jl_sym_t *jl_symbol_n(const char *str, size_t len)
{
    if (memchr(str, 0, len))
        jl_exceptionf(jl_argumenterror_type, "Symbol name may not contain \\0");
    return _jl_symbol(str, len);
}

JL_DLLEXPORT jl_sym_t *jl_get_root_symbol(void)
{
    return jl_atomic_load_relaxed(&symtab);
}

static _Atomic(uint32_t) gs_ctr = 0;  // TODO: per-module?
uint32_t jl_get_gs_ctr(void) { return jl_atomic_load_relaxed(&gs_ctr); }
void jl_set_gs_ctr(uint32_t ctr) { jl_atomic_store_relaxed(&gs_ctr, ctr); }

JL_DLLEXPORT jl_sym_t *jl_gensym(void)
{
    char name[16];
    char *n;
    uint32_t ctr = jl_atomic_fetch_add_relaxed(&gs_ctr, 1);
    n = uint2str(&name[2], sizeof(name)-2, ctr, 10);
    *(--n) = '#'; *(--n) = '#';
    return jl_symbol(n);
}

JL_DLLEXPORT jl_sym_t *jl_tagged_gensym(const char *str, size_t len)
{
    if (len == (size_t)-1) {
        len = strlen(str);
    }
    else if (memchr(str, 0, len)) {
        jl_exceptionf(jl_argumenterror_type, "Symbol name may not contain \\0");
    }
    char gs_name[14];
    size_t alloc_len = sizeof(gs_name) + len + 3;
    if (len > MAX_SYM_LEN || alloc_len > MAX_SYM_LEN)
        jl_exceptionf(jl_argumenterror_type, "Symbol name too long");
    char *name = (char*)(len >= 256 ? malloc_s(alloc_len) : alloca(alloc_len));
    char *n;
    name[0] = '#';
    name[1] = '#';
    name[2 + len] = '#';
    memcpy(name + 2, str, len);
    uint32_t ctr = jl_atomic_fetch_add_relaxed(&gs_ctr, 1);
    n = uint2str(gs_name, sizeof(gs_name), ctr, 10);
    memcpy(name + 3 + len, n, sizeof(gs_name) - (n - gs_name));
    jl_sym_t *sym = _jl_symbol(name, alloc_len - (n - gs_name)- 1);
    if (len >= 256)
        free(name);
    return sym;
}

#ifdef __cplusplus
}
#endif
