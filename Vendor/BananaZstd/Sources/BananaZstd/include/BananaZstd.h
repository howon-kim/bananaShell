// Decoder entry points from zstd 1.5.7 (BSD license).
#include <stddef.h>
size_t ZSTD_decompress(void *dst, size_t dstCapacity, const void *src, size_t compressedSize);
unsigned ZSTD_isError(size_t code);
