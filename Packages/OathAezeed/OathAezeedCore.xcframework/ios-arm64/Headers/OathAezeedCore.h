#ifndef OATH_AEZEED_CORE_H
#define OATH_AEZEED_CORE_H
#include <stdint.h>
#include <stddef.h>
int OathAezeedDecode(const uint8_t *encoded, size_t encodedLength, const uint8_t *pass, size_t passLength, uint8_t *output, size_t outputLength);
#endif
