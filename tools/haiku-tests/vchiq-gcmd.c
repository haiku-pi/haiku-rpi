/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */

/*	vchiq-gcmd — drives /dev/vchiq through its ioctls the way Broadcom's libvchiq
	does, with the firmware's gencmd service ("GCMD", what vcgencmd uses):

	  - a completion thread in AWAIT_COMPLETION (its return value: the count),
	    answering SERVICE_CLOSED with CLOSE_DELIVERED, as libvchiq's;
	  - LIB_VERSION, CONNECT, GET_CONFIG;
	  - a VCHI-style service: QUEUE_MESSAGE + DEQUEUE_MESSAGE (its return value:
	    the size), for each command given (default: version, get_mem arm);
	  - a plain service: QUEUE_MESSAGE, the reply through AWAIT_COMPLETION;
	  - CLOSE_SERVICE of both, SHUTDOWN.

	Every result line starts with "VCHIQTEST"; the last one is "VCHIQTEST
	end: PASS" or "VCHIQTEST end: FAIL (n)".

	Build: scripts/build-vchiq-test.sh (the driver's vchiq_ioctl.h, whose
	structures are those of Broadcom's userland).
*/

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioccom.h>
#include <unistd.h>

#include "vchiq_ioctl.h"


#define GCMD	VCHIQ_MAKE_FOURCC('G', 'C', 'M', 'D')
#define LIB_VERSION	8

static int sFd;
static int sFailures;
static unsigned int sHandles[2];
static sem_t sPlainReply;


static void
check(int ok, const char *what, int result)
{
	printf("VCHIQTEST %s: %s (%d%s%s)\n", what, ok ? "ok" : "FAILED", result,
		result < 0 ? ", " : "", result < 0 ? strerror(errno) : "");
	if (!ok)
		sFailures++;
}


static void
print_reply(const char *how, const char *command, const void *data, int size)
{
	int32_t result = 0;
	if (size < (int)sizeof(result)) {
		printf("VCHIQTEST %s %s: short reply (%d bytes)\n", how, command,
			size);
		sFailures++;
		return;
	}
	memcpy(&result, data, sizeof(result));
	printf("VCHIQTEST %s %s -> result %d, %d bytes: %.*s\n", how, command,
		(int)result, size, size - (int)sizeof(result),
		(const char *)data + sizeof(result));
}


static void *
completion_thread(void *unused)
{
	enum { kCount = 8, kBufferSize = VCHIQ_MAX_MSG_SIZE + 64 };
	VCHIQ_COMPLETION_DATA_T completions[kCount];
	void *buffers[kCount];
	for (int i = 0; i < kCount; i++)
		buffers[i] = malloc(kBufferSize);
	int available = kCount;

	for (;;) {
		VCHIQ_AWAIT_COMPLETION_T args = {
			.count = kCount,
			.buf = completions,
			.msgbufsize = kBufferSize,
			.msgbufcount = available,
			.msgbufs = buffers
		};
		int count = ioctl(sFd, VCHIQ_IOC_AWAIT_COMPLETION, &args);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0) {
			printf("VCHIQTEST completion thread: done (%d, %s)\n", count,
				count < 0 ? strerror(errno) : "-");
			break;
		}

		// the kernel took buffers from the top of the stack
		available = args.msgbufcount;

		for (int i = 0; i < count; i++) {
			VCHIQ_COMPLETION_DATA_T *c = &completions[i];
			int which = (int)(intptr_t)c->service_userdata;
			printf("VCHIQTEST completion: service %d, reason %d, header %p\n",
				which, c->reason, c->header);
			if (c->reason == VCHIQ_MESSAGE_AVAILABLE && c->header != NULL) {
				print_reply("completion", "measure_temp", c->header->data,
					c->header->size);
				// the buffer is the client's again
				buffers[available++] = c->header;
				sem_post(&sPlainReply);
			} else if (c->reason == VCHIQ_SERVICE_CLOSED) {
				int result = ioctl(sFd, VCHIQ_IOC_CLOSE_DELIVERED,
					sHandles[which]);
				check(result == 0, "CLOSE_DELIVERED", result);
			}
		}
	}
	return NULL;
}


static int
create_service(int which, int vchi)
{
	VCHIQ_CREATE_SERVICE_T args = {
		.params = {
			.fourcc = GCMD,
			.callback = NULL,
			.userdata = (void *)(intptr_t)which,
			.version = 1,
			.version_min = 1
		},
		.is_open = 1,
		.is_vchi = vchi
	};
	int result = ioctl(sFd, VCHIQ_IOC_CREATE_SERVICE, &args);
	check(result == 0 && args.handle != 0, vchi
		? "CREATE_SERVICE GCMD (vchi)" : "CREATE_SERVICE GCMD (plain)", result);
	sHandles[which] = args.handle;
	return result;
}


static int
queue_command(unsigned int handle, const char *command)
{
	VCHIQ_ELEMENT_T element = { command, strlen(command) + 1 };
	VCHIQ_QUEUE_MESSAGE_T args = { handle, 1, &element };
	int result = ioctl(sFd, VCHIQ_IOC_QUEUE_MESSAGE, &args);
	check(result == 0, "QUEUE_MESSAGE", result);
	return result;
}


int
main(int argc, char **argv)
{
	sFd = open("/dev/vchiq", O_RDWR);
	if (sFd < 0) {
		printf("VCHIQTEST open /dev/vchiq: %s\nVCHIQTEST end: FAIL (open)\n",
			strerror(errno));
		return 1;
	}
	sem_init(&sPlainReply, 0, 0);

	int result = ioctl(sFd, VCHIQ_IOC_LIB_VERSION, LIB_VERSION);
	check(result == 0, "LIB_VERSION", result);
	result = ioctl(sFd, VCHIQ_IOC_CONNECT, 0);
	check(result == 0, "CONNECT", result);

	VCHIQ_CONFIG_T config;
	VCHIQ_GET_CONFIG_T getConfig = { sizeof(config), &config };
	result = ioctl(sFd, VCHIQ_IOC_GET_CONFIG, &getConfig);
	check(result == 0, "GET_CONFIG", result);
	if (result == 0) {
		printf("VCHIQTEST config: max_msg_size %u, bulk_threshold %u, "
			"max_outstanding_bulks %u, max_services %u, version %d (min %d)\n",
			config.max_msg_size, config.bulk_threshold,
			config.max_outstanding_bulks, config.max_services, config.version,
			config.version_min);
	}

	pthread_t thread;
	pthread_create(&thread, NULL, completion_thread, NULL);

	// VCHI-style: messages are dequeued
	if (create_service(0, 1) == 0) {
		const char *defaults[] = { "version", "get_mem arm" };
		int commands = argc > 1 ? argc - 1 : 2;
		for (int i = 0; i < commands; i++) {
			const char *command = argc > 1 ? argv[i + 1] : defaults[i];
			if (queue_command(sHandles[0], command) != 0)
				continue;
			char buffer[VCHIQ_MAX_MSG_SIZE];
			VCHIQ_DEQUEUE_MESSAGE_T args = { sHandles[0], 1, sizeof(buffer),
				buffer };
			int size;
			do {
				size = ioctl(sFd, VCHIQ_IOC_DEQUEUE_MESSAGE, &args);
			} while (size < 0 && errno == EINTR);
			check(size > 0, "DEQUEUE_MESSAGE", size);
			if (size > 0)
				print_reply("dequeue", command, buffer, size);
		}
	}

	// plain: the reply comes with a completion
	if (create_service(1, 0) == 0 && queue_command(sHandles[1],
			"measure_temp") == 0) {
		struct timespec timeout;
		clock_gettime(CLOCK_REALTIME, &timeout);
		timeout.tv_sec += 3;
		check(sem_timedwait(&sPlainReply, &timeout) == 0,
			"reply through AWAIT_COMPLETION", 0);
	}

	for (int i = 0; i < 2; i++) {
		if (sHandles[i] == 0)
			continue;
		result = ioctl(sFd, VCHIQ_IOC_CLOSE_SERVICE, sHandles[i]);
		check(result == 0, "CLOSE_SERVICE", result);
	}

	result = ioctl(sFd, VCHIQ_IOC_SHUTDOWN, 0);
	check(result == 0, "SHUTDOWN", result);
	pthread_join(thread, NULL);
	close(sFd);

	if (sFailures == 0)
		printf("VCHIQTEST end: PASS\n");
	else
		printf("VCHIQTEST end: FAIL (%d)\n", sFailures);
	return sFailures != 0;
}
