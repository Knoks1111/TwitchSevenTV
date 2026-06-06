// fishhook.h — Facebook fishhook (MIT License)
// https://github.com/facebook/fishhook
// Permet de hooker les fonctions C de dylibs système (ex: CoreText)
// en remplaçant les entrées dans la symbol table Mach-O.

#ifndef fishhook_h
#define fishhook_h

#include <stddef.h>
#include <stdint.h>

#if !defined(FISHHOOK_EXPORT)
#define FISHHOOK_VISIBILITY __attribute__((visibility("hidden")))
#else
#define FISHHOOK_VISIBILITY __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

struct rebinding {
    const char *name;        // Nom du symbole à hooker
    void *replacement;       // Notre fonction de remplacement
    void **replaced;         // Pointeur vers l'original (sortie)
};

FISHHOOK_VISIBILITY
int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

FISHHOOK_VISIBILITY
int rebind_symbols_image(void *header, intptr_t slide,
                         struct rebinding rebindings[], size_t rebindings_nel);

#ifdef __cplusplus
}
#endif

#endif /* fishhook_h */
