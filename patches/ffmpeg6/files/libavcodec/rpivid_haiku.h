/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */
#ifndef AVCODEC_RPIVID_HAIKU_H
#define AVCODEC_RPIVID_HAIKU_H


/*!	The interface of the rpivid driver: the BCM2711's HEVC decoder block
	("brcm,bcm2711-hevc-dec", the Raspberry Pi 4).

	The block decodes a picture in two phases. Phase 1 executes a command
	buffer: 64-bit entries, a register offset in the low word and its value
	in the high word, which set the parameter sets, point the block at each
	slice's data and walk the picture's tiles or wavefront rows. Phase 2
	reconstructs the picture into the output, reading the references. The
	client builds the command entries (from its own HEVC parser); the driver
	owns every address the block uses: it checks the entries, rebases the
	bitstream addresses in them, and programs phase 2 itself.

	Memory the block reads or writes comes from the driver, by handle:
	a bitstream buffer (the client writes the slices' NAL units into it) and
	pictures (output and references, with the collocated motion vectors).
	Both are mapped into the client's team when they are created.

	Decoding is a two-stage pipeline: RPIVID_SUBMIT queues a picture and
	returns at once; the driver runs phase 1 of a picture while the block
	reconstructs the one before it (phase 2), and RPIVID_WAIT returns a
	picture's result once it is decoded - the client reads the output only
	then. Pictures of one client are decoded in the order they are
	submitted, so a picture may name earlier, still queued pictures as its
	references, and a picture buffer may be the output of a new picture while
	an earlier one still reads it as a reference.

	A copy of Haiku's headers/private/drivers/rpivid.h (the driver's interface);
	keep the two the same (rpivid_device.c checks the driver's
	RPIVID_API_VERSION).
*/


#include <stdint.h>

#include <Drivers.h>


#define RPIVID_DEVICE_PATH		"/dev/video/rpivid/0"
#define RPIVID_API_VERSION		2

#define RPIVID_MAX_REFERENCES	16
#define RPIVID_MAX_JOBS			4
	// pictures a client may have submitted and not yet waited for

enum {
	RPIVID_GET_INFO = B_DEVICE_OP_CODES_END + 0x5250,
	RPIVID_CREATE_BUFFER,
	RPIVID_CREATE_PICTURE,
	RPIVID_DELETE_BUFFER,
	RPIVID_DECODE,
	RPIVID_SUBMIT,
	RPIVID_WAIT,
};


// RPIVID_GET_INFO
typedef struct rpivid_info {
	uint32_t	api_version;
	uint32_t	hardware_version;	// the block's VERSION register
	uint32_t	clock_rate;			// Hz
	uint32_t	flags;				// RPIVID_INFO_*
	uint64_t	pictures_decoded;	// since the driver was loaded
	uint64_t	pictures_failed;
	uint64_t	overlaps;
		// phases started while the other phase of another picture ran
} rpivid_info;

#define RPIVID_INFO_BROKEN		0x01
	// the block stopped responding: it is not used again until reboot


// RPIVID_CREATE_BUFFER: a bitstream buffer, mapped write-combining
typedef struct rpivid_create_buffer {
	uint64_t	size;		// in: bytes
	uint64_t	address;	// out: the mapping in the caller's team
	uint32_t	handle;		// out
	uint32_t	_reserved;
} rpivid_create_buffer;


// RPIVID_CREATE_PICTURE: a picture in the block's output format, mapped
// read-only (the block writes it; the driver keeps the CPU's view of it
// coherent after each decode into it).
//
// Each plane is a sequence of 128-byte wide columns: byte b of row y of
// column c is at plane + c * column_stride + y * 128 + b. 8 bit: one sample
// per byte; 10 bit: three samples in each little-endian 32-bit word, lowest
// bits first (96 per column). The chroma plane holds Cb and Cr interleaved,
// half the luma rows.
typedef struct rpivid_create_picture {
	uint32_t	width;		// in: luma samples (32..4096)
	uint32_t	height;		// in
	uint32_t	bit_depth;	// in: 8 or 10
	uint32_t	flags;		// in: RPIVID_PICTURE_*

	uint64_t	address;	// out: the mapping in the caller's team
	uint64_t	size;		// out: of the mapping
	uint64_t	luma_offset;			// out: from address
	uint64_t	chroma_offset;			// out
	uint32_t	luma_column_stride;		// out: bytes
	uint32_t	chroma_column_stride;	// out
	uint32_t	columns;				// out
	uint32_t	handle;					// out
} rpivid_create_picture;

#define RPIVID_PICTURE_MOTION_VECTORS	0x01
	// with a collocated motion vector buffer: the picture may be decoded
	// with CONFIG2 "write motion vectors" and be a collocated picture
#define RPIVID_PICTURE_UNCACHED			0x02
	// mapped write-combining instead of cached (no cache maintenance;
	// slower to read)


// RPIVID_DELETE_BUFFER: either kind; also unmaps it from the caller's team
typedef struct rpivid_delete_buffer {
	uint32_t	handle;
	uint32_t	_reserved;
} rpivid_delete_buffer;


// RPIVID_SUBMIT: queues one picture; RPIVID_DECODE: submits and waits.
//
// The command entries may set the phase-1 registers (offsets 0x00 to 0x7c,
// except VERSION, the scratch buffer and command FIFO registers) and the
// probability (0x1000), scaling factor (0x2000) and slice message (0x4000)
// arrays. The value of each RPI_BFBASE (0x40) entry is a byte offset into
// the bitstream buffer, shifted right by 6, and every RPI_BFNUM must keep the
// slice inside the buffer. Pictures (output, references, collocated) must
// all have the output's size and bit depth. The entries are copied: the
// client may reuse them at once; the bitstream buffer is read until the
// picture is decoded.
typedef struct rpivid_decode {
	// in
	uint64_t	commands;		// user address of command_count entries
	uint32_t	command_count;
	uint32_t	bitstream;		// buffer handle
	uint32_t	output;			// picture handle
	uint32_t	collocated;		// picture handle (its motion vectors), 0: none
	uint32_t	references[RPIVID_MAX_REFERENCES];
		// picture handles; 0 stands for the output picture
	uint32_t	log2_ctb_size;	// 4 to 6
	uint32_t	config2;		// the phase-2 CONFIG2 register
	uint32_t	current_poc;	// the phase-2 CURRPOC register
	uint32_t	_reserved0;

	// out
	uint64_t	job;			// RPIVID_SUBMIT: for RPIVID_WAIT
	// RPIVID_DECODE: as rpivid_wait
	uint32_t	status;
	uint32_t	command_status;
	uint32_t	phase1_runs;
	uint32_t	_reserved1;
	uint64_t	queue_time;
	uint64_t	phase1_time;
	uint64_t	phase2_time;
} rpivid_decode;


// RPIVID_WAIT: the result of a submitted picture. B_OK once the picture is
// done (decoded or failed: result) - its job is then forgotten; B_WOULD_BLOCK
// or B_TIMED_OUT while it is not. Every submitted job is to be waited for:
// RPIVID_SUBMIT fails with B_BUSY while RPIVID_MAX_JOBS are not.
typedef struct rpivid_wait {
	// in
	uint64_t	job;
	int64_t		timeout;		// microseconds; 0: do not wait; < 0: no limit

	// out
	int32_t		result;			// B_OK: the output picture is decoded
	uint32_t	status;			// the STATUS register after phase 1
	uint32_t	command_status;	// CFSTATUS after phase 1 (== command_count: done)
	uint32_t	phase1_runs;	// > 1: a scratch buffer was enlarged
	uint64_t	queue_time;		// microseconds, from submit to phase 1
	uint64_t	phase1_time;	// all runs
	uint64_t	phase2_time;
} rpivid_wait;


#endif	// AVCODEC_RPIVID_HAIKU_H
