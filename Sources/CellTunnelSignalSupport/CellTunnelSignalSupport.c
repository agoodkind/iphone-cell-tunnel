//
//  CellTunnelSignalSupport.c
//  CellTunnelSignalSupport
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-23.
//  Copyright © 2026, all rights reserved.
//

#include "CellTunnelSignalSupport.h"

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "probe signal state requires lock-free atomics");

static _Atomic int first_signal;
static struct sigaction previous_interrupt_action;
static struct sigaction previous_termination_action;

static void record_signal(int signal_number) {
    if (signal_number == SIGINT || signal_number == SIGTERM) {
        int expected_signal = 0;
        atomic_compare_exchange_strong_explicit(
            &first_signal,
            &expected_signal,
            signal_number,
            memory_order_relaxed,
            memory_order_relaxed
        );
    }
}

static int set_recording_handlers(int save_previous) {
    struct sigaction action = {0};
    action.sa_handler = record_signal;
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGINT);
    sigaddset(&action.sa_mask, SIGTERM);
    struct sigaction *interrupt_previous = save_previous
        ? &previous_interrupt_action : NULL;
    struct sigaction *termination_previous = save_previous
        ? &previous_termination_action : NULL;
    if (sigaction(SIGINT, &action, interrupt_previous) != 0) {
        return errno;
    }
    if (sigaction(SIGTERM, &action, termination_previous) != 0) {
        int error_number = errno;
        if (save_previous != 0) {
            sigaction(SIGINT, &previous_interrupt_action, NULL);
        }
        return error_number;
    }
    return 0;
}

static int restore_handlers(void) {
    int first_error = 0;
    if (sigaction(SIGTERM, &previous_termination_action, NULL) != 0) {
        first_error = errno;
    }
    if (sigaction(SIGINT, &previous_interrupt_action, NULL) != 0
        && first_error == 0) {
        first_error = errno;
    }
    return first_error;
}

static char **make_arguments(
    const uint8_t *command,
    size_t command_length,
    char **storage
) {
    if (command == NULL || command_length == 0
        || command[0] == 0 || command[command_length - 1] != 0) {
        errno = EINVAL;
        return NULL;
    }
    size_t argument_count = 0;
    for (size_t index = 0; index < command_length; index += 1) {
        if (command[index] == 0) {
            argument_count += 1;
        }
    }
    char *command_storage = malloc(command_length);
    char **arguments = calloc(argument_count + 1, sizeof(char *));
    if (command_storage == NULL || arguments == NULL) {
        free(command_storage);
        free(arguments);
        errno = ENOMEM;
        return NULL;
    }
    memcpy(command_storage, command, command_length);
    arguments[0] = command_storage;
    size_t argument_index = 1;
    for (size_t index = 0; index + 1 < command_length; index += 1) {
        if (command_storage[index] == 0) {
            arguments[argument_index] = &command_storage[index + 1];
            argument_index += 1;
        }
    }
    *storage = command_storage;
    return arguments;
}

static int prepare_spawn_attributes(posix_spawnattr_t *attributes) {
    int error_number = posix_spawnattr_init(attributes);
    if (error_number != 0) {
        return error_number;
    }
    sigset_t default_signals;
    sigemptyset(&default_signals);
    sigaddset(&default_signals, SIGINT);
    sigaddset(&default_signals, SIGTERM);
    error_number = posix_spawnattr_setsigdefault(attributes, &default_signals);
    if (error_number != 0) {
        posix_spawnattr_destroy(attributes);
        return error_number;
    }
    sigset_t signal_mask;
    sigemptyset(&signal_mask);
    error_number = posix_spawnattr_setsigmask(attributes, &signal_mask);
    if (error_number != 0) {
        posix_spawnattr_destroy(attributes);
        return error_number;
    }
    short flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    error_number = posix_spawnattr_setflags(attributes, flags);
    if (error_number != 0) {
        posix_spawnattr_destroy(attributes);
    }
    return error_number;
}

static int reap_child(pid_t process_id, int *status) {
    while (waitpid(process_id, status, 0) == -1) {
        if (errno != EINTR) {
            return errno;
        }
    }
    return 0;
}

static void kill_and_reap(
    pid_t process_id,
    int32_t outcome,
    int32_t signal_number,
    CellTunnelProbeResult *result
) {
    int status = 0;
    int kill_error = 0;
    if (kill(process_id, SIGKILL) != 0 && errno != ESRCH) {
        kill_error = errno;
    }
    int error_number = reap_child(process_id, &status);
    if (kill_error != 0 || error_number != 0) {
        result->outcome = CELL_TUNNEL_PROBE_SYSTEM_ERROR;
        result->error_number = kill_error != 0 ? kill_error : error_number;
        return;
    }
    result->outcome = outcome;
    result->signal_number = signal_number;
}

static void set_exit_result(int status, CellTunnelProbeResult *result) {
    result->outcome = CELL_TUNNEL_PROBE_EXITED;
    if (WIFEXITED(status)) {
        result->status = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        result->status = 128 + WTERMSIG(status);
    }
}

static int recorded_signal(void) {
    return atomic_load_explicit(&first_signal, memory_order_relaxed);
}

static int configure_signal_events(int queue_descriptor) {
    struct kevent changes[2];
    EV_SET(&changes[0], SIGINT, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    EV_SET(&changes[1], SIGTERM, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    return kevent(queue_descriptor, changes, 2, NULL, 0, NULL);
}

static int drain_signal_events(int queue_descriptor) {
    struct kevent events[2];
    struct timespec timeout = {0};
    int event_count = kevent(
        queue_descriptor,
        NULL,
        0,
        events,
        2,
        &timeout
    );
    for (int index = 0; index < event_count; index += 1) {
        record_signal((int)events[index].ident);
    }
    return event_count;
}

static int configure_child_events(
    int queue_descriptor,
    pid_t process_id,
    uint64_t timeout_milliseconds
) {
    struct kevent changes[2];
    EV_SET(&changes[0], process_id, EVFILT_PROC, EV_ADD, NOTE_EXIT, 0, NULL);
    EV_SET(
        &changes[1],
        1,
        EVFILT_TIMER,
        EV_ADD | EV_ONESHOT,
        0,
        (intptr_t)timeout_milliseconds,
        NULL
    );
    return kevent(queue_descriptor, changes, 2, NULL, 0, NULL);
}

static void wait_for_probe(
    int queue_descriptor,
    pid_t process_id,
    CellTunnelProbeResult *result
) {
    for (;;) {
        struct kevent events[4];
        int event_count = kevent(queue_descriptor, NULL, 0, events, 4, NULL);
        if (event_count == -1) {
            if (errno == EINTR) {
                continue;
            }
            int error_number = errno;
            kill_and_reap(
                process_id,
                CELL_TUNNEL_PROBE_SYSTEM_ERROR,
                0,
                result
            );
            result->error_number = error_number;
            return;
        }
        int signal_event = 0;
        int child_exited = 0;
        int timed_out = 0;
        for (int index = 0; index < event_count; index += 1) {
            if (events[index].filter == EVFILT_SIGNAL) {
                record_signal((int)events[index].ident);
                signal_event = 1;
            } else if (events[index].filter == EVFILT_PROC) {
                child_exited = 1;
            } else if (events[index].filter == EVFILT_TIMER) {
                timed_out = 1;
            }
        }
        if (signal_event != 0) {
            kill_and_reap(
                process_id,
                CELL_TUNNEL_PROBE_INTERRUPTED,
                recorded_signal(),
                result
            );
            return;
        }
        if (child_exited != 0) {
            int status = 0;
            int error_number = reap_child(process_id, &status);
            if (error_number != 0) {
                result->outcome = CELL_TUNNEL_PROBE_SYSTEM_ERROR;
                result->error_number = error_number;
            } else {
                set_exit_result(status, result);
            }
            return;
        }
        if (timed_out != 0) {
            int status = 0;
            pid_t wait_result = waitpid(process_id, &status, WNOHANG);
            if (wait_result == process_id) {
                set_exit_result(status, result);
            } else if (wait_result == -1 && errno != EINTR) {
                result->outcome = CELL_TUNNEL_PROBE_SYSTEM_ERROR;
                result->error_number = errno;
            } else {
                kill_and_reap(
                    process_id,
                    CELL_TUNNEL_PROBE_TIMED_OUT,
                    0,
                    result
                );
            }
            return;
        }
    }
}

static void run_spawned_probe(
    int queue_descriptor,
    char **arguments,
    uint64_t timeout_milliseconds,
    CellTunnelProbeResult *result
) {
    posix_spawnattr_t attributes;
    int error_number = prepare_spawn_attributes(&attributes);
    if (error_number != 0) {
        result->outcome = CELL_TUNNEL_PROBE_SYSTEM_ERROR;
        result->error_number = error_number;
        return;
    }
    pid_t process_id = 0;
    error_number = posix_spawnp(
        &process_id,
        arguments[0],
        NULL,
        &attributes,
        arguments,
        environ
    );
    posix_spawnattr_destroy(&attributes);
    if (error_number != 0) {
        result->outcome = CELL_TUNNEL_PROBE_SYSTEM_ERROR;
        result->error_number = error_number;
        return;
    }
    if (configure_child_events(
        queue_descriptor,
        process_id,
        timeout_milliseconds
    ) != 0) {
        error_number = errno;
        kill_and_reap(
            process_id,
            CELL_TUNNEL_PROBE_SYSTEM_ERROR,
            0,
            result
        );
        result->error_number = error_number;
    } else {
        wait_for_probe(queue_descriptor, process_id, result);
    }
}

void cell_tunnel_probe_run(
    const uint8_t *command,
    size_t command_length,
    uint64_t timeout_milliseconds,
    CellTunnelProbeResult *result
) {
    *result = (CellTunnelProbeResult){0};
    char *command_storage = NULL;
    char **arguments = make_arguments(command, command_length, &command_storage);
    if (arguments == NULL) {
        result->outcome = CELL_TUNNEL_PROBE_SYSTEM_ERROR;
        result->error_number = errno;
        return;
    }
    int queue_descriptor = kqueue();
    if (queue_descriptor == -1) {
        result->outcome = CELL_TUNNEL_PROBE_SYSTEM_ERROR;
        result->error_number = errno;
        free(arguments);
        free(command_storage);
        return;
    }
    atomic_store_explicit(&first_signal, 0, memory_order_relaxed);
    int error_number = set_recording_handlers(1);
    int handlers_installed = error_number == 0;
    if (error_number == 0) {
        if (configure_signal_events(queue_descriptor) != 0) {
            error_number = errno;
        }
    }
    if (error_number == 0 && drain_signal_events(queue_descriptor) == -1) {
        error_number = errno;
    }
    int signal_number = recorded_signal();
    if (error_number != 0) {
        result->outcome = CELL_TUNNEL_PROBE_SYSTEM_ERROR;
        result->error_number = error_number;
    } else if (signal_number != 0) {
        result->outcome = CELL_TUNNEL_PROBE_INTERRUPTED;
        result->signal_number = signal_number;
    } else {
        run_spawned_probe(
            queue_descriptor,
            arguments,
            timeout_milliseconds,
            result
        );
    }
    int drain_error = 0;
    int restore_error = 0;
    if (handlers_installed != 0) {
        if (drain_signal_events(queue_descriptor) == -1) {
            drain_error = errno;
        }
        restore_error = restore_handlers();
    }
    signal_number = recorded_signal();
    if (signal_number != 0) {
        result->outcome = CELL_TUNNEL_PROBE_INTERRUPTED;
        result->signal_number = signal_number;
    } else if (drain_error != 0 || restore_error != 0) {
        result->outcome = CELL_TUNNEL_PROBE_SYSTEM_ERROR;
        if (drain_error != 0) {
            result->error_number = drain_error;
        } else {
            result->error_number = restore_error;
        }
    }
    close(queue_descriptor);
    free(arguments);
    free(command_storage);
}
