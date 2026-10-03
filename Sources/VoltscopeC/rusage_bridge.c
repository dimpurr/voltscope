#include "include/VoltscopeC.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <string.h>

int voltscope_proc_pid_rusage_v6(int pid, struct rusage_info_v6 *info) {
    return proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)info);
}

int voltscope_get_process_info(int pid, int *parent_pid, char *command, size_t command_size) {
    struct proc_bsdinfo info;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (size != sizeof(info)) {
        return -1;
    }
    if (parent_pid != NULL) {
        *parent_pid = (int)info.pbi_ppid;
    }
    if (command != NULL && command_size > 0) {
        strlcpy(command, info.pbi_comm, command_size);
    }
    return 0;
}
