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

// Returns the parent PID for the given pid via proc_pidinfo(PROC_PIDTBSDINFO).
// Returns -1 on failure (errno set), or if the pid is not visible to us.
int voltscope_get_parent_pid(int pid);

#endif
