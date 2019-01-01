/*
 ** Copyright (C) 2018-2019 Vincent Sallaberry
 ** vsyswatch <https://github.com/vsallaberry/vsyswatch>
 **
 ** This program is free software; you can redistribute it and/or modify
 ** it under the terms of the GNU General Public License as published by
 ** the Free Software Foundation; either version 3 of the License, or
 ** (at your option) any later version.
 **
 ** This program is distributed in the hope that it will be useful,
 ** but WITHOUT ANY WARRANTY; without even the implied warranty of
 ** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 ** GNU General Public License for more details.
 **
 ** You should have received a copy of the GNU General Public License along
 ** with this program; if not, write to the Free Software Foundation, Inc.,
 ** 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 **
 ** -------------------------------------------------------------------------
 ** vsyswatch:
 **   little utility for MacOS watching for availability of differents
 **   resources like network, battery, ...
 **/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/time.h>
#include <unistd.h>
#include <notify.h>
#include <pthread.h>

#include "vsyswatch.h"

typedef struct {
    pthread_t       tid;
    int             notify_fd;
    void            (*callback)(void *, void *);
    void *          callback_data;
} file_data_t;

static void * file_notify(void * data);

void vsyswatch_file_stop(vsyswatch_ctx_t * ctx) {
    if (ctx && ctx->file) {
        file_data_t * file = (file_data_t *) ctx->file;
        close(file->notify_fd);
        pthread_join(file->tid, NULL);
        ctx->file = NULL;
        free(file);
    }
}

int vsyswatch_file(vsyswatch_ctx_t * ctx, void (*callback)(void*,void*), void * callback_data) {
    if (ctx == NULL) {
        fprintf(stderr, "%s(): error ctx NULL\n", __func__);
        return -1;
    }
    if (ctx->file) {
        fprintf(stderr, "%s(): error file is already watched\n", __func__);
        return -1;
    }
    file_data_t * file = calloc(1, sizeof(file_data_t));
    ctx->file = file;
    if (file == NULL) {
        fprintf(stderr, "%s(): malloc error: %s\n", __func__, strerror(errno));
        return -1;
    }
    file->callback = callback;
    file->callback_data = callback_data;
    file->notify_fd = -1;
    return pthread_create(&file->tid, NULL, file_notify, ctx);
}

static void * file_notify(void * data) {
    vsyswatch_ctx_t *   ctx = (vsyswatch_ctx_t *) data;
    file_data_t *       file = (file_data_t *) ctx->file;
    fd_set              readfds, errfds;
    int                 nf = -1;
    int                 t;
    int                 ret;

    if (nf < 0) {
        fprintf(stderr, "%s(): illegal fd, exiting.\n", __func__);
        return (void *) -1;
    }

    file->notify_fd = nf;
    while (1) {
        FD_ZERO(&readfds);
        FD_ZERO(&errfds);
        FD_SET(nf, &readfds);
        FD_SET(nf, &errfds);

        ret = select(nf + 1, &readfds, NULL, &errfds, NULL);
        if (ret == 0) {
            fprintf(stderr, "%s(): notify select timeout\n", __func__);
            continue ;
        }
        if (ret < 0 && errno == EINTR)
            continue;
        if (ret < 0) {
            fprintf(stderr, "%s(): notify select error: %s\n", __func__, strerror(errno));
            break ;
        }
        if (FD_ISSET(nf, &errfds) || !FD_ISSET(nf, &readfds)) {
            fprintf(stderr, "%s(): notify other error\n", __func__);
            break ;
        }

        if (read(nf, &t, sizeof(int)) < 0) {
            fprintf(stderr, "%s(): notify read error: %s\n", __func__, strerror(errno));
            break;
        }

        t = ntohl(t);

        fflush(stderr);
    }
    fprintf(stderr, "file: shutting down\n");
    file->notify_fd = -1;
    close(nf);
    return (void*) 0;
}

