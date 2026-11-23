#include <fcntl.h>
#include <sys/mman.h>

// shm_open is variadic, which swift can't call
static inline int dawn_shm_open(const char *name, int flags, mode_t mode) {
    return shm_open(name, flags, mode);
}
