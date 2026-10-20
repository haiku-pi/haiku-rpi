/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */


/*	The rpivid block's phase-1 command buffer (see rpivid_cmd.h).

	The sequence - which registers, in which order, for slice segments, tiles
	and wavefront rows - is the one the Raspberry Pi Linux driver (hevc_dec)
	programs; the block has no other documentation.
*/


#include "rpivid_cmd.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "libavutil/error.h"


/* Phase-1 registers */
enum {
	REG_SPS0			= 0x00,
	REG_SPS1			= 0x04,
	REG_PPS				= 0x08,
	REG_SLICE			= 0x0c,
	REG_TILESTART		= 0x10,
	REG_TILEEND			= 0x14,
	REG_SLICESTART		= 0x18,
	REG_MODE			= 0x1c,
	REG_QP				= 0x30,
	REG_CONTROL			= 0x34,
	REG_STATUS			= 0x38,
	REG_BFBASE			= 0x40,
	REG_BFNUM			= 0x44,
	REG_BFCONTROL		= 0x48,
	REG_SLICECMDS		= 0x60,
	REG_BEGINTILEEND	= 0x64,
	REG_TRANSFER		= 0x68,
	REG_PROBABILITIES	= 0x1000,
	REG_SCALING_FACTORS	= 0x2000,
	REG_SLICE_MESSAGES	= 0x4000,
};

#define MODE_WPP			1u
#define MODE_TILE			0xffffu
#define MODE_LAST_COLUMN	(1u << 17)
#define MODE_LAST_ROW		(1u << 18)

#define BFCONTROL_EMULATION	(1u << 6)
#define BFCONTROL_STOP		(1u << 7)

/* TRANSFER: save the CABAC state, or reload the saved one */
#define PROB_BACKUP			((20u << 12) | (20u << 6))
#define PROB_RELOAD			((20u << 12) | (20u << 0))

/* A picture's command buffer beyond this is a broken stream */
#define MAX_ENTRIES			(1u << 18)

#define PROBABILITY_COUNT	154
#define PROBABILITY_BYTES	156


/* The CABAC contexts' initValues (H.265 9.3.2.2) in the block's order, for
   initType 0 (I), 1 and 2 */
static const uint8_t kProbabilityInit[3][PROBABILITY_BYTES] = {
	{
		153, 200, 139, 141, 157, 154, 154, 154, 154, 154, 184, 154, 154,
		154, 184, 63, 154, 154, 154, 154, 154, 154, 154, 154, 154, 154,
		154, 154, 154, 153, 138, 138, 111, 141, 94, 138, 182, 154, 154,
		154, 140, 92, 137, 138, 140, 152, 138, 139, 153, 74, 149, 92,
		139, 107, 122, 152, 140, 179, 166, 182, 140, 227, 122, 197, 110,
		110, 124, 125, 140, 153, 125, 127, 140, 109, 111, 143, 127, 111,
		79, 108, 123, 63, 110, 110, 124, 125, 140, 153, 125, 127, 140,
		109, 111, 143, 127, 111, 79, 108, 123, 63, 91, 171, 134, 141,
		138, 153, 136, 167, 152, 152, 139, 139, 111, 111, 125, 110, 110,
		94, 124, 108, 124, 107, 125, 141, 179, 153, 125, 107, 125, 141,
		179, 153, 125, 107, 125, 141, 179, 153, 125, 140, 139, 182, 182,
		152, 136, 152, 136, 153, 136, 139, 111, 136, 139, 111, 0, 0,
	},
	{
		153, 185, 107, 139, 126, 197, 185, 201, 154, 149, 154, 139, 154,
		154, 154, 152, 110, 122, 95, 79, 63, 31, 31, 153, 153, 168,
		140, 198, 79, 124, 138, 94, 153, 111, 149, 107, 167, 154, 154,
		154, 154, 196, 196, 167, 154, 152, 167, 182, 182, 134, 149, 136,
		153, 121, 136, 137, 169, 194, 166, 167, 154, 167, 137, 182, 125,
		110, 94, 110, 95, 79, 125, 111, 110, 78, 110, 111, 111, 95,
		94, 108, 123, 108, 125, 110, 94, 110, 95, 79, 125, 111, 110,
		78, 110, 111, 111, 95, 94, 108, 123, 108, 121, 140, 61, 154,
		107, 167, 91, 122, 107, 167, 139, 139, 155, 154, 139, 153, 139,
		123, 123, 63, 153, 166, 183, 140, 136, 153, 154, 166, 183, 140,
		136, 153, 154, 166, 183, 140, 136, 153, 154, 170, 153, 123, 123,
		107, 121, 107, 121, 167, 151, 183, 140, 151, 183, 140, 0, 0,
	},
	{
		153, 160, 107, 139, 126, 197, 185, 201, 154, 134, 154, 139, 154,
		154, 183, 152, 154, 137, 95, 79, 63, 31, 31, 153, 153, 168,
		169, 198, 79, 224, 167, 122, 153, 111, 149, 92, 167, 154, 154,
		154, 154, 196, 167, 167, 154, 152, 167, 182, 182, 134, 149, 136,
		153, 121, 136, 122, 169, 208, 166, 167, 154, 152, 167, 182, 125,
		110, 124, 110, 95, 94, 125, 111, 111, 79, 125, 126, 111, 111,
		79, 108, 123, 93, 125, 110, 124, 110, 95, 94, 125, 111, 111,
		79, 125, 126, 111, 111, 79, 108, 123, 93, 121, 140, 61, 154,
		107, 167, 91, 107, 107, 167, 139, 139, 170, 154, 139, 153, 139,
		123, 123, 63, 124, 166, 183, 140, 136, 153, 154, 166, 183, 140,
		136, 153, 154, 166, 183, 140, 136, 153, 154, 170, 153, 138, 138,
		122, 121, 122, 121, 167, 151, 183, 140, 151, 183, 140, 0, 0,
	},
};


void
ff_rpivid_commands_init(RpividCommands* commands)
{
	memset(commands, 0, sizeof(*commands));
}


void
ff_rpivid_commands_free(RpividCommands* commands)
{
	free(commands->entries);
	memset(commands, 0, sizeof(*commands));
}


static void
put(RpividCommands* commands, uint32_t offset, uint32_t value)
{
	if (commands->error != 0)
		return;
	if (commands->count == commands->capacity) {
		uint32_t capacity = commands->capacity != 0
			? commands->capacity * 2 : 4096;
		uint64_t* entries;
		if (capacity > MAX_ENTRIES) {
			commands->error = AVERROR(EINVAL);
			return;
		}
		entries = realloc(commands->entries, capacity * sizeof(uint64_t));
		if (entries == NULL) {
			commands->error = AVERROR(ENOMEM);
			return;
		}
		commands->entries = entries;
		commands->capacity = capacity;
	}
	commands->entries[commands->count++] = offset | ((uint64_t)value << 32);
}


static void
put_bytes(RpividCommands* commands, uint32_t offset, const uint8_t* bytes,
	uint32_t count)
{
	uint32_t i;
	for (i = 0; i < count; i += 4) {
		put(commands, offset + i, bytes[i] | ((uint32_t)bytes[i + 1] << 8)
			| ((uint32_t)bytes[i + 2] << 16) | ((uint32_t)bytes[i + 3] << 24));
	}
}


/* The CABAC initial state of the slice (9.3.2.2), then saved: tiles and
   wavefront rows start again from it. */
static void
write_probabilities(RpividCommands* commands, const RpividSliceParams* slice)
{
	/* initType: I 0, P 1, B 2; cabac_init_flag swaps P and B */
	const unsigned initType = slice->cabac_init && slice->type != RPIVID_SLICE_I
		? slice->type + 1u : 2u - slice->type;
	const uint8_t* init = kProbabilityInit[initType];
	const int qp = slice->qp < 0 ? 0 : (slice->qp > 51 ? 51 : slice->qp);
	uint8_t state[PROBABILITY_BYTES];
	unsigned i;

	for (i = 0; i < PROBABILITY_COUNT; i++) {
		const int m = (init[i] >> 4) * 5 - 45;
		const int n = ((init[i] & 15) << 3) - 16;
		int value = 2 * (((m * qp) >> 4) + n) - 127;

		value ^= value >> 31;
		if (value > 124)
			value = 124 + (value & 1);
		state[i] = (uint8_t)value;
	}
	state[PROBABILITY_COUNT] = state[PROBABILITY_COUNT + 1] = 0;

	put_bytes(commands, REG_PROBABILITIES, state, PROBABILITY_BYTES);
	put(commands, REG_TRANSFER, PROB_BACKUP);
}


static void
write_bitstream(RpividCommands* commands, const RpividSliceParams* slice)
{
	const uint32_t offset = slice->data_offset & 63;

	/* in 64-byte units of the bitstream buffer: the driver rebases it */
	put(commands, REG_BFBASE, slice->data_offset >> 6);
	put(commands, REG_BFNUM, slice->data_size);
	put(commands, REG_BFCONTROL, offset | BFCONTROL_STOP);
	/* the data has its emulation prevention bytes: the block removes them */
	put(commands, REG_BFCONTROL, offset | BFCONTROL_EMULATION);
}


/* SLICE without the size of the entry's last CTB, which new_entry_point()
   adds */
static uint32_t
slice_constant(const RpividSliceParams* slice)
{
	uint32_t value = slice->max_num_merge_cand
		| ((uint32_t)slice->num_refs[0] << 4)
		| ((uint32_t)slice->num_refs[1] << 8)
		| ((uint32_t)slice->type << 12);

	if (slice->sao_luma)
		value |= 1u << 14;
	if (slice->sao_chroma)
		value |= 1u << 15;
	if (slice->type == RPIVID_SLICE_B && slice->mvd_l1_zero)
		value |= 1u << 16;
	return value;
}


static void
new_slice_segment(RpividCommands* commands, const RpividSliceParams* slice)
{
	const RpividPictureParams* picture = commands->picture;
	uint32_t sps1;

	put(commands, REG_SPS0, picture->log2_min_cb_size
		| ((uint32_t)picture->log2_ctb_size << 4)
		| ((uint32_t)picture->log2_min_tb_size << 8)
		| ((uint32_t)picture->log2_max_tb_size << 12)
		| ((uint32_t)picture->bit_depth << 16)
		| ((uint32_t)picture->bit_depth << 20)
		| ((uint32_t)picture->max_transform_depth_intra << 24)
		| ((uint32_t)picture->max_transform_depth_inter << 28));

	if (picture->pcm) {
		sps1 = picture->pcm_bit_depth
			| ((uint32_t)picture->pcm_bit_depth_chroma << 4)
			| ((uint32_t)picture->log2_min_pcm_cb_size << 8)
			| ((uint32_t)picture->log2_max_pcm_cb_size << 12);
	} else {
		/* what the PCM fields hold when their syntax elements are all 0 */
		sps1 = 1u | (1u << 4) | (3u << 8) | (3u << 12);
	}
	sps1 |= ((uint32_t)picture->chroma_format_idc << 16)
		| ((uint32_t)(picture->amp != 0) << 18)
		| ((uint32_t)(picture->pcm != 0) << 19)
		| ((uint32_t)(picture->scaling_list != 0) << 20)
		| ((uint32_t)(picture->strong_intra_smoothing != 0) << 21);
	put(commands, REG_SPS1, sps1);

	put(commands, REG_PPS,
		(uint32_t)(picture->log2_ctb_size - picture->diff_cu_qp_delta_depth)
		| ((uint32_t)(picture->cu_qp_delta != 0) << 4)
		| ((uint32_t)(picture->transquant_bypass != 0) << 5)
		| ((uint32_t)(picture->transform_skip != 0) << 6)
		| ((uint32_t)(picture->sign_data_hiding != 0) << 7)
		| (((uint32_t)(picture->cb_qp_offset + slice->cb_qp_offset) & 0xff) << 8)
		| (((uint32_t)(picture->cr_qp_offset + slice->cr_qp_offset) & 0xff)
			<< 16)
		| ((uint32_t)(picture->constrained_intra_pred != 0) << 24));

	if (commands->start_ts == 0 && picture->scaling_list
		&& picture->scaling_factors != NULL) {
		put_bytes(commands, REG_SCALING_FACTORS, picture->scaling_factors,
			RPIVID_SCALING_FACTOR_BYTES);
	}

	if (!slice->dependent) {
		commands->slice_start = slice->segment_address % commands->ctb_width
			| ((slice->segment_address / commands->ctb_width) << 16);
	}
	put(commands, REG_SLICESTART, commands->slice_start);
}


static void
message(RpividCommands* commands, uint32_t value)
{
	if (commands->message_count >= RPIVID_MAX_SLICE_MESSAGES) {
		commands->error = AVERROR(EINVAL);
		return;
	}
	commands->messages[commands->message_count++] = (uint16_t)value;
}


/* A reference list's descriptors: slot and kind, POC, and for weighted
   prediction the luma and both chroma weights and offsets */
static void
reference_messages(RpividCommands* commands, const RpividSliceParams* slice,
	unsigned list, int weighted)
{
	unsigned i;
	for (i = 0; i < slice->num_refs[list]; i++) {
		message(commands, slice->ref_slot[list][i]
			| (slice->ref_long_term[list][i] ? 1u << 4 : 0)
			| (weighted ? 3u << 5 : 0));
		message(commands, (uint32_t)slice->ref_poc[list][i] & 0xffff);
		if (weighted) {
			int c;
			message(commands, slice->luma_log2_weight_denom
				| (((uint32_t)slice->luma_weight[list][i] & 0x1ff) << 3));
			message(commands, (uint32_t)slice->luma_offset[list][i] & 0xff);
			for (c = 0; c < 2; c++) {
				message(commands, slice->chroma_log2_weight_denom
					| (((uint32_t)slice->chroma_weight[list][i][c] & 0x1ff)
						<< 3));
				message(commands,
					(uint32_t)slice->chroma_offset[list][i][c] & 0xff);
			}
		}
	}
}


/* The slice messages: slice kind, reference descriptors, deblocking, chroma
   QP offsets. Every slice sends all of them, I slices too: the block keeps
   the deblocking state of the previous slice otherwise. */
static void
slice_messages(RpividCommands* commands, const RpividSliceParams* slice)
{
	const RpividPictureParams* picture = commands->picture;
	uint32_t kind, deblocking;
	int collocatedFromL0, acrossSlices;

	commands->message_count = 0;
	kind = slice->type == RPIVID_SLICE_I ? 1
		: (slice->type == RPIVID_SLICE_P ? 2 : 3);
	kind |= ((uint32_t)slice->num_refs[0] << 2)
		| ((uint32_t)slice->num_refs[1] << 6)
		| ((uint32_t)slice->max_num_merge_cand << 11);
	collocatedFromL0 = !picture->slice_temporal_mvp
		|| slice->type != RPIVID_SLICE_B || slice->collocated_from_l0;
	kind |= (uint32_t)collocatedFromL0 << 14;

	if (slice->type != RPIVID_SLICE_I) {
		const int weighted = slice->type == RPIVID_SLICE_P
			? picture->weighted_pred : picture->weighted_bipred;
		/* NoBackwardPredFlag: no reference follows the current picture */
		int noBackward = 1;
		unsigned list, i;
		for (list = 0; list < 2; list++) {
			for (i = 0; i < slice->num_refs[list]; i++) {
				if (slice->ref_poc[list][i] > slice->poc)
					noBackward = 0;
			}
		}
		message(commands, kind | ((uint32_t)noBackward << 10));
		reference_messages(commands, slice, 0, weighted);
		reference_messages(commands, slice, 1, weighted);
	} else
		message(commands, kind);

	/* Across-slice and across-tile filtering mean nothing without slice or
	   tile boundaries: such pictures send them as set and clear (the form
	   the block was proved on). */
	acrossSlices = picture->one_slice_segment || slice->loop_filter_across_slices;
	deblocking = ((uint32_t)slice->beta_offset_div2 & 15)
		| (((uint32_t)slice->tc_offset_div2 & 15) << 4)
		| (slice->deblocking_disabled ? 1u << 8 : 0)
		| (acrossSlices ? 1u << 9 : 0)
		| (picture->tiles && picture->loop_filter_across_tiles ? 1u << 10 : 0);
	message(commands, deblocking);
	message(commands, (((uint32_t)slice->cr_qp_offset & 31) << 5)
		| ((uint32_t)slice->cb_qp_offset & 31));
}


static void
program_slice_messages(RpividCommands* commands)
{
	uint32_t i;
	put(commands, REG_SLICECMDS,
		commands->message_count | (commands->slice_index << 8));
	for (i = 0; i < commands->message_count; i++)
		put(commands, REG_SLICE_MESSAGES + 4 * i, commands->messages[i]);
}


/* SLICE: the constant part and the size of the entry's last CTB (smaller at
   the right and bottom edges of the picture) */
static void
write_slice(RpividCommands* commands, uint32_t constant, uint32_t lastColumn,
	uint32_t lastRow)
{
	const RpividPictureParams* picture = commands->picture;
	const uint32_t ctbSize = 1u << picture->log2_ctb_size;
	const uint32_t partialWidth = picture->width & (ctbSize - 1);
	const uint32_t partialHeight = picture->height & (ctbSize - 1);
	const uint32_t width = lastColumn + 1 < commands->ctb_width
		|| partialWidth == 0 ? ctbSize : partialWidth;
	const uint32_t height = lastRow + 1 < commands->ctb_height
		|| partialHeight == 0 ? ctbSize : partialHeight;

	put(commands, REG_SLICE, constant | (width << 17) | (height << 24));
}


static void
new_entry_point(RpividCommands* commands, int beginTileEnd, int resetQp,
	uint32_t mode, uint32_t tileX, uint32_t tileY, uint32_t ctbX, uint32_t ctbY,
	int qp, uint32_t constant)
{
	const RpividPictureParams* picture = commands->picture;
	const uint32_t endX = picture->column_bd[tileX + 1] - 1;
	const uint32_t endY = mode == MODE_WPP ? ctbY : picture->row_bd[tileY + 1] - 1;

	put(commands, REG_TILESTART,
		picture->column_bd[tileX] | (picture->row_bd[tileY] << 16));
	put(commands, REG_TILEEND, endX | (endY << 16));
	if (beginTileEnd)
		put(commands, REG_BEGINTILEEND, endX | (endY << 16));
	write_slice(commands, constant, endX, endY);
	if (resetQp)
		put(commands, REG_QP, 6 * (picture->bit_depth - 8) + qp);
	put(commands, REG_MODE, mode
		| (endX == commands->ctb_width - 1 ? MODE_LAST_COLUMN : 0)
		| (endY == commands->ctb_height - 1 ? MODE_LAST_ROW : 0));
	put(commands, REG_CONTROL, ctbX | (ctbY << 16));

	commands->entry_tile_x = tileX;
	commands->entry_tile_y = tileY;
	commands->entry_ctb_x = ctbX;
	commands->entry_ctb_y = ctbY;
	commands->entry_qp = qp;
	commands->entry_slice = constant;
}


//	#pragma mark - wavefront parallel processing


static void
wpp_pause(RpividCommands* commands, uint32_t row)
{
	put(commands, REG_STATUS, (row << 18) | 0x25);
	put(commands, REG_TRANSFER, PROB_BACKUP);
	put(commands, REG_MODE, row == commands->ctb_height - 1 ? 0x70000 : 0x30000);
	put(commands, REG_CONTROL, (row << 16) + 2);
}


/* The wavefront rows from the last entry point up to \a lastRow */
static void
wpp_fill_rows(RpividCommands* commands, uint32_t lastRow)
{
	const uint32_t lastColumn = commands->ctb_width - 1;

	while (commands->entry_ctb_y < lastRow && commands->error == 0) {
		if (commands->ctb_width > 2)
			wpp_pause(commands, commands->entry_ctb_y);
		put(commands, REG_STATUS,
			(commands->entry_ctb_y << 18) | (lastColumn << 5) | 2);
		/* two CTBs wide: the saved state is still the initial one */
		put(commands, REG_TRANSFER,
			commands->ctb_width == 2 ? PROB_BACKUP : PROB_RELOAD);
		new_entry_point(commands, 0, 1, MODE_WPP, 0, 0, 0,
			commands->entry_ctb_y + 1, commands->entry_qp,
			commands->entry_slice);
	}
}


static void
wpp_end_previous_slice(RpividCommands* commands)
{
	wpp_fill_rows(commands, commands->previous_ctb_y);
	if (commands->entry_ctb_x < 2 && commands->ctb_width > 2
		&& (commands->entry_ctb_y < commands->start_ctb_y
			|| commands->start_ctb_x > 2)) {
		wpp_pause(commands, commands->previous_ctb_y);
	}
	put(commands, REG_STATUS, 1 | (commands->previous_ctb_x << 5)
		| (commands->previous_ctb_y << 18));
	if (commands->start_ctb_x == 2 || (commands->ctb_width == 2
			&& commands->entry_ctb_y < commands->start_ctb_y)) {
		put(commands, REG_TRANSFER, PROB_BACKUP);
	}
}


static void
wpp_add_slice(RpividCommands* commands, const RpividSliceParams* slice)
{
	const int independent = !slice->dependent;
	int resetQp = 1;

	if (commands->start_ts != 0)
		wpp_end_previous_slice(commands);
	slice_messages(commands, slice);
	write_bitstream(commands, slice);
	if (commands->start_ts == 0 || independent || commands->ctb_width == 1)
		write_probabilities(commands, slice);
	else if (commands->start_ctb_x == 0)
		put(commands, REG_TRANSFER, PROB_RELOAD);
	else
		resetQp = 0;
	program_slice_messages(commands);
	new_slice_segment(commands, slice);
	new_entry_point(commands, independent, resetQp, MODE_WPP, 0, 0,
		commands->start_ctb_x, commands->start_ctb_y, slice->qp,
		slice_constant(slice));
}


//	#pragma mark - tiles (a picture without them is one tile)


static uint32_t
tile_of(uint32_t ctb, const uint32_t* boundaries, uint32_t count)
{
	uint32_t tile = 0;
	while (tile + 1 < count && ctb >= boundaries[tile + 1])
		tile++;
	return tile;
}


/* The tiles from the last entry point up to (tileX, tileY) */
static void
tile_fill(RpividCommands* commands, uint32_t lastTileX, uint32_t lastTileY)
{
	const RpividPictureParams* picture = commands->picture;

	while ((commands->entry_tile_y < lastTileY
			|| (commands->entry_tile_y == lastTileY
				&& commands->entry_tile_x < lastTileX))
		&& commands->error == 0) {
		uint32_t tileX = commands->entry_tile_x;
		uint32_t tileY = commands->entry_tile_y;

		put(commands, REG_STATUS, 2 | ((picture->column_bd[tileX + 1] - 1) << 5)
			| ((picture->row_bd[tileY + 1] - 1) << 18));
		put(commands, REG_TRANSFER, PROB_RELOAD);
		if (++tileX >= picture->tile_columns) {
			tileX = 0;
			tileY++;
		}
		new_entry_point(commands, 0, 1, MODE_TILE, tileX, tileY,
			picture->column_bd[tileX], picture->row_bd[tileY],
			commands->entry_qp, commands->entry_slice);
	}
}


static void
tile_add_slice(RpividCommands* commands, const RpividSliceParams* slice)
{
	const RpividPictureParams* picture = commands->picture;
	const uint32_t tileX = tile_of(commands->start_ctb_x, picture->column_bd,
		picture->tile_columns);
	const uint32_t tileY = tile_of(commands->start_ctb_y, picture->row_bd,
		picture->tile_rows);
	const uint32_t previousTileX = tile_of(commands->previous_ctb_x,
		picture->column_bd, picture->tile_columns);
	const uint32_t previousTileY = tile_of(commands->previous_ctb_y,
		picture->row_bd, picture->tile_rows);
	int resetQp;

	if (commands->start_ts != 0) {
		tile_fill(commands, previousTileX, previousTileY);
		put(commands, REG_STATUS, 1 | (commands->previous_ctb_x << 5)
			| (commands->previous_ctb_y << 18));
	}
	slice_messages(commands, slice);
	write_bitstream(commands, slice);
	resetQp = commands->start_ts == 0 || !slice->dependent
		|| tileX != previousTileX || tileY != previousTileY;
	if (resetQp)
		write_probabilities(commands, slice);
	program_slice_messages(commands);
	new_slice_segment(commands, slice);
	new_entry_point(commands, !slice->dependent, resetQp, MODE_TILE, tileX,
		tileY, commands->start_ctb_x, commands->start_ctb_y, slice->qp,
		slice_constant(slice));
}


//	#pragma mark - interface


void
ff_rpivid_commands_begin(RpividCommands* commands,
	const RpividPictureParams* picture)
{
	const uint32_t ctbSize = 1u << picture->log2_ctb_size;

	commands->count = 0;
	commands->error = 0;
	commands->picture = picture;
	commands->ctb_width = (picture->width + ctbSize - 1) >> picture->log2_ctb_size;
	commands->ctb_height = (picture->height + ctbSize - 1)
		>> picture->log2_ctb_size;
	commands->slice_index = 0;
	commands->slice_start = 0;
	commands->entry_tile_x = commands->entry_tile_y = 0;
	commands->entry_ctb_x = commands->entry_ctb_y = 0;
	commands->entry_qp = 0;
	commands->entry_slice = 0;
}


int
ff_rpivid_commands_add_slice(RpividCommands* commands,
	const RpividSliceParams* slice)
{
	const RpividPictureParams* picture = commands->picture;
	const uint32_t ctbCount = commands->ctb_width * commands->ctb_height;
	uint32_t previous;

	if (commands->error != 0)
		return commands->error;
	if (slice->segment_address >= ctbCount || slice->type > RPIVID_SLICE_I
		|| slice->num_refs[0] > 16 || slice->num_refs[1] > 16
		|| (commands->slice_index == 0 && slice->segment_address != 0)) {
		commands->error = AVERROR(EINVAL);
		return commands->error;
	}

	commands->start_ts = picture->ctb_addr_rs_to_ts != NULL
		? (uint32_t)picture->ctb_addr_rs_to_ts[slice->segment_address]
		: slice->segment_address;
	commands->start_ctb_x = slice->segment_address % commands->ctb_width;
	commands->start_ctb_y = slice->segment_address / commands->ctb_width;
	if (commands->start_ts == 0)
		previous = 0;
	else if (picture->ctb_addr_ts_to_rs != NULL)
		previous = (uint32_t)picture->ctb_addr_ts_to_rs[commands->start_ts - 1];
	else
		previous = commands->start_ts - 1;
	commands->previous_ctb_x = previous % commands->ctb_width;
	commands->previous_ctb_y = previous / commands->ctb_width;

	if (picture->entropy_coding_sync)
		wpp_add_slice(commands, slice);
	else
		tile_add_slice(commands, slice);
	commands->slice_index++;
	return commands->error;
}


int
ff_rpivid_commands_end(RpividCommands* commands)
{
	const RpividPictureParams* picture = commands->picture;

	if (commands->error == 0 && commands->slice_index == 0)
		commands->error = AVERROR(EINVAL);
	if (commands->error != 0)
		return commands->error;

	if (picture->entropy_coding_sync) {
		wpp_fill_rows(commands, commands->ctb_height - 1);
		if (commands->entry_ctb_x < 2 && commands->ctb_width > 2)
			wpp_pause(commands, commands->ctb_height - 1);
	} else
		tile_fill(commands, picture->tile_columns - 1, picture->tile_rows - 1);
	put(commands, REG_STATUS, 1 | ((commands->ctb_width - 1) << 5)
		| ((commands->ctb_height - 1) << 18));
	return commands->error != 0 ? commands->error : (int)commands->count;
}


uint32_t
ff_rpivid_config2(const RpividPictureParams* picture, int write_mv)
{
	uint32_t value = picture->bit_depth | ((uint32_t)picture->bit_depth << 4);

	if (picture->bit_depth != 8)
		value |= (1u << 8) | (1u << 9);
	value |= (uint32_t)picture->log2_ctb_size << 10;
	if (picture->constrained_intra_pred)
		value |= 1u << 13;
	if (picture->strong_intra_smoothing)
		value |= 1u << 14;
	if (write_mv)
		value |= 1u << 15;
	value |= (uint32_t)picture->log2_parallel_merge_level << 16;
	if (picture->slice_temporal_mvp)
		value |= 1u << 19;
	if (picture->pcm && picture->pcm_loop_filter_disabled)
		value |= 1u << 20;
	value |= ((uint32_t)picture->cb_qp_offset & 31) << 21;
	value |= ((uint32_t)picture->cr_qp_offset & 31) << 26;
	return value;
}


/* An 8x8 list upsampled to size x size, the DC value replacing the first */
static void
expand_list(uint8_t* out, const uint8_t* list, unsigned size, uint8_t dc)
{
	const unsigned factor = size / 8;
	unsigned x, y;

	for (y = 0; y < size; y++) {
		for (x = 0; x < size; x++)
			out[y * size + x] = list[(y / factor) * 8 + x / factor];
	}
	out[0] = dc;
}


void
ff_rpivid_scaling_factors(uint8_t out[RPIVID_SCALING_FACTOR_BYTES],
	const uint8_t list4x4[6][16], const uint8_t list8x8[6][64],
	const uint8_t list16x16[6][64], const uint8_t dc16x16[6],
	const uint8_t list32x32[2][64], const uint8_t dc32x32[2])
{
	unsigned matrix;

	/* 4x4 lists at 0x000 (16 bytes each), 8x8 at 0x060 (64), 16x16 at 0x1e0
	   (256), 32x32 at 0x7e0 (1024; intra and inter luma) */
	memset(out, 0, RPIVID_SCALING_FACTOR_BYTES);
	for (matrix = 0; matrix < 6; matrix++) {
		memcpy(out + 0x000 + 16 * matrix, list4x4[matrix], 16);
		memcpy(out + 0x060 + 64 * matrix, list8x8[matrix], 64);
		expand_list(out + 0x1e0 + 256 * matrix, list16x16[matrix], 16,
			dc16x16[matrix]);
	}
	for (matrix = 0; matrix < 2; matrix++) {
		expand_list(out + 0x7e0 + 1024 * matrix, list32x32[matrix], 32,
			dc32x32[matrix]);
	}
}
