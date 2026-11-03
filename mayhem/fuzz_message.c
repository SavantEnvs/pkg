/*
 * Copy of tests/fuzz/fuzz_message.c with one guard: pkg_message_from_str() treats len==0 as "str is
 * NUL-terminated" and calls strlen(), but libFuzzer's empty input is not NUL-terminated, so the
 * upstream harness aborts on the empty input before it can fuzz anything.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "pkg.h"
#include "private/pkg.h"

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	struct pkg *pkg = NULL;

	if (size == 0)
		return (0);

	if (pkg_new(&pkg, PKG_INSTALLED) != EPKG_OK)
		return (0);

	pkg_message_from_str(pkg, (const char *)data, size);

	pkg_free(pkg);
	return (0);
}
