#include "include/VoltscopeC.h"
#include <libproc.h>
#include <sys/proc_info.h>

int voltscope_proc_pid_rusage_v6(int pid, struct rusage_info_v6 *info) {
    return proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)info);
}

int voltscope_get_parent_pid(int pid) {
    struct proc_bsdinfo info;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (size != sizeof(info)) {
        return -1;
    }
    return (int)info.pbi_ppid;
}
