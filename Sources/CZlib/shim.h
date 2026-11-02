#pragma once
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <zlib.h>

// Apple's COMPRESSION_ZLIB is RFC 1951 raw DEFLATE at level 5, without an RFC 1950 wrapper.
static inline size_t compositor_zlib_encode_raw(uint8_t *dst, size_t dst_size,
                                               const uint8_t *src, size_t src_size) {
    if (!dst || !dst_size || (!src && src_size) || dst_size > UINT_MAX || src_size > UINT_MAX) return 0;
    z_stream stream = {0};
    if (deflateInit2(&stream, 5, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) return 0;
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_size;
    stream.next_out = dst;
    stream.avail_out = (uInt)dst_size;
    const int status = deflate(&stream, Z_FINISH);
    const size_t count = status == Z_STREAM_END ? stream.total_out : 0;
    deflateEnd(&stream);
    return count;
}

static inline size_t compositor_zlib_decode_raw(uint8_t *dst, size_t dst_size,
                                               const uint8_t *src, size_t src_size) {
    if (!dst || !dst_size || (!src && src_size) || dst_size > UINT_MAX || src_size > UINT_MAX) return 0;
    z_stream stream = {0};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return 0;
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_size;
    stream.next_out = dst;
    stream.avail_out = (uInt)dst_size;
    const int status = inflate(&stream, Z_FINISH);
    // Like compression_decode_buffer, a full destination may hold only the decoded prefix.
    const int valid = status == Z_STREAM_END || ((status == Z_OK || status == Z_BUF_ERROR) && stream.avail_out == 0);
    const size_t count = valid ? stream.total_out : 0;
    inflateEnd(&stream);
    return count;
}
