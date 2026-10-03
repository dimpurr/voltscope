#ifndef VOLTSCOPE_C_H
#define VOLTSCOPE_C_H

#include <sys/resource.h>

// Wraps proc_pid_rusage(pid, RUSAGE_INFO_V6, &info).
// Apple's API takes a `rusage_info_t *` (which is `void **`) parameter that
// callers populate by casting a pointer to the version-specific struct.
// Bridging that calling convention through Swift is fragile, so we wrap it.
//
// Returns 0 on success, -1 on failure (errno set).
int voltscope_proc_pid_rusage_v6(int pid, struct rusage_info_v6 *info);

// Reads parent PID and process command name via proc_pidinfo(PROC_PIDTBSDINFO).
// Returns 0 on success, -1 on failure (errno set), or if the pid is not visible.
int voltscope_get_process_info(int pid, int *parent_pid, char *command, size_t command_size);

#endif
