#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern "C" int *text_diff(char *a, char *b);

/* data[0] picks where the remaining bytes split into the FROM and TO texts. */
extern "C" int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	char *a, *b;
	size_t rest, alen;

	if (size < 1)
		return (-1);
	rest = size - 1;
	alen = data[0] % (rest + 1);
	a = strndup((const char *)data + 1, alen);
	b = strndup((const char *)data + 1 + alen, rest - alen);
	if (a == NULL || b == NULL) {
		free(a);
		free(b);
		return (0);
	}

	free(text_diff(a, b));
	free(a);
	free(b);
	return (0);
}
