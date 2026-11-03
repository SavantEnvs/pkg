/*
 * Copy of tests/fuzz/fuzz_plist.c with two changes, both to make the plist parser reachable:
 *  - upstream opens its input with fmemopen(NULL, 0, "w+"); glibc rejects a zero-size buffer (EINVAL),
 *    so every input returned before plist_parse_line() ran (46 edges whatever the seed). The input is
 *    now read through fmemopen() over a copy of itself.
 *  - the plist stage directory was "/", where no plist file entry (bin/hello, ...) exists, so every file
 *    line failed at fstatat(). It is now a private tree, created once in LLVMFuzzerInitialize and only
 *    read afterwards, holding the files the seeds name under /usr/local.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#include "pkg.h"
#include "private/pkg.h"

static char stage[256];

static void
put_file(const char *path, const char *content)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (fd == -1)
		return;
	(void)write(fd, content, strlen(content));
	close(fd);
}

static void
remove_stage(void)
{
	static const char *const files[] = {
		"usr/local/bin/hello", "usr/local/bin/hello-link",
		"usr/local/share/hello/README",
	};
	static const char *const dirs[] = {
		"usr/local/share/hello", "usr/local/share", "usr/local/bin",
		"usr/local", "usr", "",
	};
	char path[512];

	for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
		snprintf(path, sizeof(path), "%s/%s", stage, files[i]);
		unlink(path);
	}
	for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
		snprintf(path, sizeof(path), "%s/%s", stage, dirs[i]);
		rmdir(path);
	}
}

int
LLVMFuzzerInitialize(int *argc, char ***argv)
{
	const char *tmp = getenv("TMPDIR");
	char path[512];

	(void)argc;
	(void)argv;
	snprintf(stage, sizeof(stage), "%s/pkg-plist-stage.XXXXXX",
	    tmp != NULL && tmp[0] != '\0' ? tmp : "/tmp");
	if (mkdtemp(stage) == NULL)
		return (0);
	atexit(remove_stage);

	snprintf(path, sizeof(path), "%s/usr", stage);
	mkdir(path, 0755);
	snprintf(path, sizeof(path), "%s/usr/local", stage);
	mkdir(path, 0755);
	snprintf(path, sizeof(path), "%s/usr/local/bin", stage);
	mkdir(path, 0755);
	snprintf(path, sizeof(path), "%s/usr/local/share", stage);
	mkdir(path, 0755);
	snprintf(path, sizeof(path), "%s/usr/local/share/hello", stage);
	mkdir(path, 0755);
	snprintf(path, sizeof(path), "%s/usr/local/bin/hello", stage);
	put_file(path, "hello\n");
	snprintf(path, sizeof(path), "%s/usr/local/share/hello/README", stage);
	put_file(path, "hello readme\n");
	snprintf(path, sizeof(path), "%s/usr/local/bin/hello-link", stage);
	(void)symlink("hello", path);
	return (0);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	struct pkg *p = NULL;
	struct plist *pl;
	FILE *f;
	char *copy;
	char *line = NULL;
	size_t linecap = 0;
	ssize_t linelen;

	if (size == 0 || stage[0] == '\0')
		return (0);

	if (pkg_new(&p, PKG_FILE) != EPKG_OK)
		return (0);

	pkg_set(p, PKG_ATTR_PREFIX, "/");
	pl = plist_new(p, stage);
	if (pl == NULL) {
		pkg_free(p);
		return (0);
	}

	copy = malloc(size);
	if (copy == NULL) {
		plist_free(pl);
		pkg_free(p);
		return (0);
	}
	memcpy(copy, data, size);
	f = fmemopen(copy, size, "r");
	if (f == NULL) {
		free(copy);
		plist_free(pl);
		pkg_free(p);
		return (0);
	}

	/* Multi-line parsing via the exported per-line API */
	while ((linelen = getline(&line, &linecap, f)) > 0) {
		if (line[linelen - 1] == '\n')
			line[linelen - 1] = '\0';
		plist_parse_line(pl, line);
	}
	free(line);
	fclose(f);
	free(copy);

	plist_free(pl);
	pkg_free(p);
	return (0);
}
